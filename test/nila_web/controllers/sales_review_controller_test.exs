defmodule NilaWeb.SalesReviewControllerTest do
  import NilaWeb.ApiContract, only: [contract_response: 2]
  use NilaWeb.ConnCase, async: true
  import Nila.GstFixtures
  import Ecto.Query
  alias Nila.{Clients, Repo, Storage}
  alias Nila.Gst.Intake.Dump
  alias Nila.Gst.Sales.{Batch, Months}
  alias Nila.Gst.Sales.Invoice.Corrections
  alias Nila.Gst.Sales.Review.Resolutions
  alias Nila.Gst.Sales.Excel.Workbook

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Review client",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    dump =
      work_dump!(org, client, "2025-10", "sales", "%PDF-1.4 fake bytes", user.id)
      |> Repo.reload!()

    {:ok, batch} = Batch.create(org.id, client.id, Ecto.UUID.generate())
    key = "test/review/#{Ecto.UUID.generate()}/original.pdf"
    {:ok, _} = Storage.put(key, "%PDF-1.4 source")
    on_exit(fn -> Storage.delete(key) end)

    dump =
      dump
      |> Ecto.Changeset.change(
        sales_batch_id: batch.id,
        file_keys: [key],
        meta: Map.put(dump.meta, "original_name", "sales.pdf")
      )
      |> Repo.update!()

    {:ok, month} = Months.get_by_period(org.id, client.id, "2025-10")
    invoice = hd(month.invoices)

    %{
      conn: log_in_user(conn, user),
      user: user,
      org: org,
      client: client,
      dump: dump,
      month: month,
      invoice: invoice,
      path:
        "/api/workspace/sales/#{client.id}/2025-10/invoices/#{URI.encode_www_form(invoice["id"])}"
    }
  end

  test "loads a real invoice with source evidence, server comparisons and queue", %{
    conn: conn,
    path: path,
    invoice: invoice,
    client: client,
    dump: dump
  } do
    response = get(conn, path)
    body = contract_response(response, 200)
    assert body["invoice"]["id"] == invoice["id"]
    assert body["can_edit"]
    assert body["source"]["name"] == "sales.pdf"
    assert body["source"]["url"] == "/gst/#{client.id}/2025-10/original/#{dump.id}/0"
    assert is_list(body["source"]["pages"])
    row = Enum.find(body["queue"], &(&1["id"] == invoice["id"]))
    assert row["customer"] == body["invoice"]["buyer_name"]
    assert row["amount"] == Enum.find(body["totals"], &(&1["field"] == "total"))["calculated"]
    assert Enum.all?(body["totals"], &is_binary(&1["calculated"]))
    assert body["lines"] != []
    assert Enum.all?(hd(body["lines"])["values"], fn {_field, value} -> is_binary(value) end)
    assert get_resp_header(response, "cache-control") == ["private, no-store"]
  end

  test "review projection distinguishes residual tax from an independent calculation", %{
    user: user,
    client: client,
    invoice: invoice
  } do
    alias NilaWeb.Gst.SalesReviewWorkspace
    scope = Nila.Accounts.Scope.for_user(user)
    {:ok, context} = SalesReviewWorkspace.load(scope, client, "2025-10", invoice["id"])
    assert SalesReviewWorkspace.project(context).tax_calculation == nil

    valuation = %{
      "basis" => "rsp",
      "method" => "invoice_value_residual",
      "status" => "derived",
      "reconciliation" => %{"difference" => 0.27, "scope" => "hsn_b2b_net"}
    }

    context = put_in(context.item.invoice["tax_valuation"], valuation)
    projected = SalesReviewWorkspace.project(context)
    assert projected.tax_calculation.method == "invoice_value_residual"
    assert projected.tax_calculation.detail =~ "₹0.27 difference"
    assert projected.tax_calculation.label == "Derived from invoice value"

    context = put_in(context.item.invoice["tax_valuation"]["method"], "reviewer_entered")
    assert SalesReviewWorkspace.project(context).tax_calculation.label == "Edited tax amounts"

    context = put_in(context.item.invoice["tax_valuation"]["status"], "unresolved")
    assert SalesReviewWorkspace.project(context).tax_calculation.method == "unresolved"
  end

  test "serves original workbook cells with invoice row links and retained report headings", %{
    conn: conn,
    path: path,
    dump: dump,
    month: month,
    invoice: invoice
  } do
    bytes = File.read!("test/fixtures/sales_excel/standard.xlsx")
    {:ok, workbook} = Workbook.read(bytes)
    sheet = hd(workbook.sheets)
    header = hd(sheet.rows)
    source_row = Enum.at(sheet.rows, 1)
    file = "standard.xlsx"
    key = "test/review/#{Ecto.UUID.generate()}/standard.xlsx"
    {:ok, _} = Storage.put(key, bytes)
    on_exit(fn -> Storage.delete(key) end)

    source_invoice =
      invoice
      |> Map.put("source_filename", file)
      |> Map.put("source_sheet", sheet.name)
      |> Map.put("source_rows", [source_row.row])

    month
    |> Ecto.Changeset.change(invoices: [source_invoice])
    |> Repo.update!()

    dump
    |> Ecto.Changeset.change(
      invoices: [source_invoice],
      file_keys: [key],
      meta: %{
        "excel_import" => true,
        "original_name" => file,
        "return_report" => %{
          "rows" => [
            %{
              "source_filename" => file,
              "sheet" => sheet.name,
              "headers" => header.cells,
              "columns" => %{"number" => "A", "date" => "B", "txval" => "C"}
            }
          ]
        }
      }
    )
    |> Repo.update!()

    review = conn |> get(path) |> contract_response(200)

    assert review["source"]["spreadsheet"]["selected"] ==
             [%{"file" => file, "sheet" => sheet.name, "rows" => [source_row.row]}]

    data = conn |> get(path <> "/source") |> contract_response(200)
    assert data["file"] == file
    assert data["sheet"] == sheet.name
    assert data["files"] == [%{"name" => file, "sheets" => [sheet.name]}]
    assert data["header_rows"] == [header.row]
    assert data["invoice_column"] == "A"
    assert data["relevant_columns"] == ["A", "B", "C"]

    assert Enum.find(data["rows"], &(&1["row"] == source_row.row))["invoice_ids"] == [
             invoice["id"]
           ]

    assert Enum.find(data["rows"], &(&1["row"] == header.row))["cells"] == header.cells
    assert Enum.find(data["rows"], &(&1["row"] == header.row))["invoice_ids"] == []
    assert data["download_url"] =~ "/original/#{dump.id}/0"
    assert conn |> get(path <> "/source?sheet=missing") |> contract_response(404)

    unrelated_key = "test/review/#{Ecto.UUID.generate()}/other.xlsx"
    {:ok, _} = Storage.put(unrelated_key, "not a workbook")
    on_exit(fn -> Storage.delete(unrelated_key) end)

    dump
    |> Ecto.Changeset.change(
      file_keys: [key, unrelated_key],
      meta:
        dump.meta
        |> Map.put("excel_import", true)
        |> Map.put("file_manifest", [
          %{"filename" => file},
          %{"filename" => "other.xlsx"}
        ])
        |> Map.put("return_report", %{
          "rows" => [
            %{
              "source_filename" => file,
              "sheet" => sheet.name,
              "headers" => header.cells,
              "columns" => %{"number" => "A"}
            }
          ]
        })
    )
    |> Repo.update!()

    assert conn |> get(path <> "/source") |> contract_response(200)
    assert conn |> get(path <> "/source?file=other.xlsx") |> contract_response(404)
  end

  test "buyer name warning separates the comparison from dated lookup evidence", %{
    conn: conn,
    path: path,
    invoice: invoice,
    month: month,
    dump: dump
  } do
    replace = fn invoices ->
      Enum.map(invoices, fn row ->
        if row["id"] == invoice["id"],
          do:
            row
            |> Map.put("buyer_gstin", "33AEWPH4158J1Z3")
            |> Map.put("buyer_name", "Siemens Healthcare Pvt Ltd"),
          else: row
      end)
    end

    month |> Ecto.Changeset.change(invoices: replace.(month.invoices)) |> Repo.update!()
    dump |> Ecto.Changeset.change(invoices: replace.(dump.invoices)) |> Repo.update!()

    Repo.insert!(%Nila.Gst.Portal.TaxpayerLookup{
      gstin: "33AEWPH4158J1Z3",
      legal_name: "Registered Customer Limited",
      registration_status: "Active",
      checked_at: DateTime.utc_now(),
      payload: %{}
    })

    body = conn |> get(path) |> contract_response(200)
    issue = Enum.find(body["issues"], &(&1["code"] == "buyer_gst_name_review"))

    assert issue["message"] ==
             "The bill says “Siemens Healthcare Pvt Ltd”. GST records say “Registered Customer Limited”."

    assert issue["lookup_details"] =~ "Active. Checked"
    assert issue["lookup_details"] =~ "not on the invoice date"
  end

  test "displays the GST treatment's place of supply without inventing a captured source fact", %{
    conn: conn,
    path: path,
    invoice: invoice,
    month: month,
    dump: dump
  } do
    replace = fn invoices ->
      Enum.map(invoices, fn row ->
        if row["id"] == invoice["id"],
          do: row |> Map.delete("place_of_supply") |> Map.put("buyer_gstin", "33AEWPH4158J1Z3"),
          else: row
      end)
    end

    month |> Ecto.Changeset.change(invoices: replace.(month.invoices)) |> Repo.update!()
    dump |> Ecto.Changeset.change(invoices: replace.(dump.invoices)) |> Repo.update!()

    body = conn |> get(path) |> contract_response(200)
    assert body["invoice"]["place_of_supply"] == "Tamil Nadu (33)"
    assert body["facts"]["place_of_supply"] == ""
  end

  test "facts, line and printed-total edits persist source corrections without rewriting extraction",
       %{
         conn: conn,
         path: path,
         invoice: invoice,
         org: org,
         client: client,
         user: user,
         dump: dump
       } do
    changed =
      conn
      |> patch(path, %{section: "facts", values: %{buyer_name: "Corrected buyer"}})
      |> contract_response(200)

    assert changed["facts"]["buyer_name"] == "Corrected buyer"

    line =
      conn
      |> patch(path, %{section: "line", line_index: 0, values: %{description: "Corrected item"}})
      |> contract_response(200)

    assert hd(line["lines"])["values"]["description"] == "Corrected item"

    totals =
      conn
      |> patch(path, %{section: "totals", values: %{printed_grand_total: "999.50"}})
      |> contract_response(200)

    assert totals["printed_totals"]["printed_grand_total"] == "999.5"
    corrections = Corrections.list(org.id, client.id, invoice["id"])
    assert length(corrections) == 3
    assert Enum.all?(corrections, &(&1.corrected_by_id == user.id))
    assert Repo.get!(Dump, dump.id).invoices == dump.invoices
  end

  test "invalid values and unknown fields cannot create corrections", %{
    conn: conn,
    path: path,
    invoice: invoice,
    org: org,
    client: client
  } do
    for payload <- [
          %{section: "facts", values: %{buyer_gstin: "invalid"}},
          %{section: "facts", values: %{invoice_date: "not a date"}},
          %{section: "facts", values: %{seller_gstin: "33AEWPH4158J1Z3"}},
          %{section: "line", line_index: 999, values: %{description: "No line"}},
          %{section: "line", line_index: 0, values: %{taxable_value: "-1"}},
          %{section: "totals", values: %{printed_grand_total: %{nested: "bad"}}}
        ] do
      assert conn |> patch(path, payload) |> contract_response(422)
    end

    assert Corrections.list(org.id, client.id, invoice["id"]) == []
  end

  test "confirmation accepts only a current nonblocking issue on this invoice", %{
    conn: conn,
    path: path,
    month: month,
    user: user
  } do
    body = conn |> get(path) |> contract_response(200)
    issue = Enum.find(body["issues"], & &1["can_confirm"])
    assert issue

    confirmed =
      conn |> post(path <> "/confirm", %{target: issue["target"]}) |> contract_response(200)

    refute Enum.any?(
             confirmed["issues"],
             &(&1["target"] == issue["target"] and &1["can_confirm"])
           )

    assert Enum.any?(
             Resolutions.list(month.id),
             &(&1.target == issue["target"] and &1.decided_by_id == user.id)
           )

    assert conn |> post(path <> "/confirm", %{target: "made-up|target"}) |> contract_response(422)
    assert conn |> post(path <> "/confirm", %{target: issue["target"]}) |> contract_response(422)
  end

  test "filed month shows its snapshot and rejects edits and confirmations", %{
    conn: conn,
    path: path,
    month: month
  } do
    month |> Ecto.Changeset.change(filed_at: DateTime.utc_now()) |> Repo.update!()
    body = conn |> get(path) |> contract_response(200)
    refute body["can_edit"]
    assert body["lock_reason"] =~ "filed"

    assert conn
           |> patch(path, %{section: "facts", values: %{buyer_name: "No"}})
           |> contract_response(409)

    assert conn |> post(path <> "/confirm", %{target: "anything"}) |> contract_response(409)
  end

  test "missing and foreign invoices never fall back to another invoice, viewers cannot mutate",
       %{conn: conn, path: path, client: client, org: org, user: user} do
    assert build_conn() |> get(path) |> contract_response(401)
    %{user: other} = user_with_org_fixture()
    assert build_conn() |> log_in_user(other) |> get(path) |> contract_response(404)

    assert conn
           |> get("/api/workspace/sales/#{client.id}/2025-10/invoices/missing")
           |> contract_response(404)

    assert conn |> get(String.replace(path, "2025-10", "2025-09")) |> contract_response(404)

    Repo.update_all(
      from(m in Nila.Orgs.Membership, where: m.user_id == ^user.id and m.org_id == ^org.id),
      set: [role: "viewer"]
    )

    body = conn |> get(path) |> contract_response(200)
    refute body["can_edit"]

    assert conn
           |> patch(path, %{section: "facts", values: %{buyer_name: "No"}})
           |> contract_response(403)

    assert conn |> post(path <> "/confirm", %{target: "anything"}) |> contract_response(403)
  end
end
