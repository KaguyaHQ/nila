defmodule NilaWeb.SalesReportControllerTest do
  use NilaWeb.ConnCase, async: true
  import NilaWeb.ApiContract, only: [contract_response: 2]
  alias Nila.Gst.Sales.{Months, ReportImport}

  @tag :tmp_dir
  test "imports a section packet as one report with each file retained", %{
    conn: conn,
    tmp_dir: tmp
  } do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Nila.Clients.create_client(%{
        org_id: org.id,
        name: "Packet client",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    b2b =
      csv_row([
        "GSTIN/UIN of Recipient",
        "",
        "Invoice Number",
        "Invoice date",
        "Invoice Value",
        "Place Of Supply",
        "",
        "",
        "",
        "",
        "Rate",
        "Taxable Value"
      ]) <>
        csv_row([
          "33AABCP9487A1ZG",
          "",
          "PACKET1",
          "01/08/2026",
          "118",
          "33-Tamil Nadu",
          "N",
          "",
          "Regular B2B",
          "",
          "18",
          "100",
          "0"
        ])

    b2cs =
      csv_row(["Type", "Place Of Supply", "", "Rate", "Taxable Value"]) <>
        csv_row(["OE", "33-Tamil Nadu", "", "18", "50", "0"])

    b2b_path = Path.join(tmp, "B2B.csv")
    b2cs_path = Path.join(tmp, "B2CS.csv")
    File.write!(b2b_path, b2b)
    File.write!(b2cs_path, b2cs)

    path = "/api/workspace/sales/#{client.id}/2026-08/reports"
    conn = log_in_user(conn, user)

    uploads = [
      %Plug.Upload{path: b2b_path, filename: "B2B.csv"},
      %Plug.Upload{path: b2cs_path, filename: "B2CS.csv"}
    ]

    assert %{"ok" => true, "dump_id" => dump_id} =
             conn |> post(path, %{"files" => uploads}) |> json_response(200)

    dump = Nila.Repo.get!(Nila.Gst.Intake.Dump, dump_id)
    assert length(dump.file_keys) == 2
    assert Enum.map(dump.meta["file_manifest"], & &1["filename"]) == ["B2B.csv", "B2CS.csv"]

    assert Enum.map(dump.meta["file_manifest"], & &1["sha256"]) ==
             Enum.map([b2b, b2cs], &Nila.Gst.Sales.Excel.ReportPacket.digest/1)

    assert MapSet.new(Enum.map(dump.meta["return_report"]["rows"], & &1["source_filename"])) ==
             MapSet.new(["B2B.csv", "B2CS.csv"])

    assert {:ok, ^b2b} = Nila.Storage.get(Enum.at(dump.file_keys, 0))
    assert {:ok, ^b2cs} = Nila.Storage.get(Enum.at(dump.file_keys, 1))
    on_exit(fn -> Enum.each(dump.file_keys, &Nila.Storage.delete/1) end)

    assert %{"error" => message} =
             conn |> post(path, %{"files" => uploads}) |> contract_response(422)

    assert message =~ "already has a sales report"

    %{user: other} = user_with_org_fixture()

    assert %{"error" => _} =
             conn
             |> recycle()
             |> log_in_user(other)
             |> delete(path, %{"dump_id" => dump_id})
             |> json_response(404)

    assert Nila.Repo.get!(Nila.Gst.Intake.Dump, dump_id).status == "extracted"

    month =
      Nila.Repo.get_by!(Nila.Gst.Sales.Month,
        org_id: org.id,
        client_id: client.id,
        period: "2026-08"
      )

    month
    |> Ecto.Changeset.change(state: "filed", filed_at: DateTime.utc_now())
    |> Nila.Repo.update!()

    assert %{"error" => filed_message} =
             conn |> delete(path, %{"dump_id" => dump_id}) |> json_response(422)

    assert filed_message =~ "filed"

    month
    |> Nila.Repo.reload!()
    |> Ecto.Changeset.change(state: "worked", filed_at: nil)
    |> Nila.Repo.update!()

    assert %{"ok" => true} = conn |> delete(path, %{"dump_id" => dump_id}) |> json_response(200)
    assert Nila.Repo.get!(Nila.Gst.Intake.Dump, dump_id).status == "discarded"
    assert {:ok, ^b2b} = Nila.Storage.get(Enum.at(dump.file_keys, 0))

    %{"reports" => []} = conn |> get(path) |> contract_response(200)
    {:ok, refreshed} = Months.get_by_period(org.id, client.id, "2026-08")
    assert refreshed.invoices == []
    assert refreshed.derived_gstr1["b2cs"] in [nil, []]

    assert %{"ok" => true, "dump_id" => replacement_id} =
             conn |> post(path, %{"files" => uploads}) |> json_response(200)

    assert replacement_id != dump_id
    replacement_keys = Nila.Repo.get!(Nila.Gst.Intake.Dump, replacement_id).file_keys
    on_exit(fn -> Enum.each(replacement_keys, &Nila.Storage.delete/1) end)
  end

  defp csv_row(values), do: Enum.join(values, ",") <> "\n"

  @tag :tmp_dir
  test "B2CS and HSN summaries without invoices can download a working and JSON", %{
    conn: conn,
    tmp_dir: tmp
  } do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Nila.Clients.create_client(%{
        org_id: org.id,
        name: "Summary client",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    b2cs =
      csv_row([
        "Type",
        "Place Of Supply",
        "Applicable % of Tax Rate",
        "Rate",
        "Taxable Value",
        "Cess Amount",
        "E-Commerce GSTIN"
      ]) <>
        csv_row(["OE", "33-Tamil Nadu", "", "18", "100", "0", ""])

    b2cs_path = Path.join(tmp, "B2CS.csv")
    File.write!(b2cs_path, b2cs)

    hsn_headers = [
      "HSN",
      "Description",
      "UQC",
      "Total Quantity",
      "",
      "Rate",
      "Taxable Value",
      "Integrated Tax Amount",
      "Central Tax Amount",
      "State/UT Tax Amount",
      "Cess Amount"
    ]

    {:ok, hsn_bytes} =
      XlsxWriter.generate([
        sheet("HSN", hsn_headers, ["998311", "Services", "NA", 1, "", 18, 100, 0, 9, 9, 0])
      ])

    hsn_path = Path.join(tmp, "HSN(B2C).xlsx")
    File.write!(hsn_path, hsn_bytes)
    conn = log_in_user(conn, user)
    report_path = "/api/workspace/sales/#{client.id}/2026-08/reports"

    uploads = [
      %Plug.Upload{path: b2cs_path, filename: "B2CS.csv"},
      %Plug.Upload{path: hsn_path, filename: "HSN(B2C).xlsx"}
    ]

    assert %{"ok" => true, "dump_id" => dump_id} =
             conn |> post(report_path, %{"files" => uploads}) |> json_response(200)

    dump = Nila.Repo.get!(Nila.Gst.Intake.Dump, dump_id)
    on_exit(fn -> Enum.each(dump.file_keys, &Nila.Storage.delete/1) end)
    assert dump.invoices == []

    workspace =
      conn |> get("/api/workspace/sales/#{client.id}/2026-08") |> json_response(200)

    assert Enum.all?(workspace["exports"]["items"], & &1["enabled"])
    assert get(conn, "/gstr1/#{client.id}/2026-08/workings.xlsx").status == 200

    json = get(conn, "/gstr1/#{client.id}/2026-08/return.json")
    assert json.status == 200

    assert [%{"txval" => 100.0}] =
             Jason.decode!(json.resp_body)["b2cs"] |> Enum.map(&Map.take(&1, ["txval"]))
  end

  @tag :tmp_dir
  test "a correction names the source when two HSN sheets share a row number", %{
    conn: conn,
    tmp_dir: tmp
  } do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Nila.Clients.create_client(%{
        org_id: org.id,
        name: "Two HSN sources",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    b2b =
      csv_row([
        "GSTIN/UIN of Recipient",
        "",
        "Invoice Number",
        "Invoice date",
        "Invoice Value",
        "Place Of Supply",
        "",
        "",
        "",
        "",
        "Rate",
        "Taxable Value"
      ]) <>
        csv_row([
          "33AABCP9487A1ZG",
          "",
          "PACKET2",
          "01/08/2026",
          "118",
          "33-Tamil Nadu",
          "N",
          "",
          "Regular B2B",
          "",
          "18",
          "100",
          "0"
        ])

    b2b_path = Path.join(tmp, "B2B.csv")
    File.write!(b2b_path, b2b)

    hsn_headers = [
      "HSN",
      "Description",
      "UQC",
      "Total Quantity",
      "",
      "Rate",
      "Taxable Value",
      "Integrated Tax Amount",
      "Central Tax Amount",
      "State/UT Tax Amount",
      "Cess Amount"
    ]

    hsn_uploads =
      for {name, taxable} <- [{"HSN(B2B).xlsx", 100}, {"HSN(B2C).xlsx", 50}] do
        {:ok, bytes} =
          XlsxWriter.generate([
            sheet("HSN", hsn_headers, ["998311", "Services", "NA", 1, "", 18, taxable, 0, 9, 9, 0])
          ])

        source = Path.join(tmp, name)
        File.write!(source, bytes)
        %Plug.Upload{path: source, filename: name}
      end

    conn = log_in_user(conn, user)
    path = "/api/workspace/sales/#{client.id}/2026-08/reports"
    uploads = [%Plug.Upload{path: b2b_path, filename: "B2B.csv"} | hsn_uploads]

    assert %{"ok" => true, "dump_id" => dump_id} =
             conn |> post(path, %{"files" => uploads}) |> json_response(200)

    file_keys = Nila.Repo.get!(Nila.Gst.Intake.Dump, dump_id).file_keys
    on_exit(fn -> Enum.each(file_keys, &Nila.Storage.delete/1) end)

    %{"reports" => [report]} = conn |> get(path) |> contract_response(200)
    hsn_rows = Enum.filter(report["rows"], &(&1["sheet"] == "HSN"))

    assert Enum.map(hsn_rows, &{&1["row"], &1["source_filename"]}) ==
             [{2, "HSN(B2B).xlsx"}, {2, "HSN(B2C).xlsx"}]

    params = %{
      "dump_id" => dump_id,
      "basis" => report["basis"],
      "sheet" => "HSN",
      "row" => 2,
      "values" => %{"qty" => 2.0}
    }

    assert %{"error" => _} = conn |> patch(path, params) |> contract_response(422)

    selected = Map.put(params, "source_filename", "HSN(B2B).xlsx")
    assert %{"ok" => true} = conn |> patch(path, selected) |> contract_response(200)
    assert %{"error" => _} = conn |> patch(path, selected) |> contract_response(422)

    %{"reports" => [updated]} = conn |> get(path) |> contract_response(200)

    assert Enum.map(Enum.filter(updated["rows"], &(&1["sheet"] == "HSN")), & &1["values"]["qty"]) ==
             [2.0, 1.0]
  end

  @tag :tmp_dir
  test "unchanged report upload, reviewed correction, stale rejection and tenant isolation", %{
    conn: conn,
    tmp_dir: tmp
  } do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Nila.Clients.create_client(%{
        org_id: org.id,
        name: "Report client",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    path = "/api/workspace/sales/#{client.id}/2026-08/reports"

    {:ok, bytes} =
      XlsxWriter.generate([
        sheet(
          "B2B",
          [
            "GSTIN/UIN of Supplier",
            "Return Period",
            "Invoice number",
            "Invoice Date",
            "Invoice Value",
            "Rate of GST",
            "Taxable Value",
            "IGST Amount",
            "Cess Amount",
            "CGST Amount",
            "SGST Amount",
            "GSTIN/UIN of Recipient",
            "Place of Supply(POS)",
            "Reverse Charge",
            "Invoice Type"
          ],
          [
            client.gstin,
            "082026",
            "TEST1",
            "2026-08-01",
            118,
            18,
            100,
            0,
            0,
            9,
            9,
            "33AABCP9487A1ZG",
            "33",
            "N",
            "R"
          ]
        ),
        sheet(
          "HSNB2B",
          [
            "GSTIN/UIN of Supplier",
            "Return Period",
            "HSN",
            "UQC",
            "Total Quantity",
            "Rate",
            "Taxable Value",
            "IGST Amount",
            "CGST Amount",
            "SGST Amount",
            "Cess Amount"
          ],
          [client.gstin, "082026", "998599", "NA", 0, "", 100, 0, 9, 9, 0]
        ),
        sheet(
          "Docs",
          [
            "GSTIN/UIN of Supplier",
            "Return Period",
            "Nature of document",
            "From serial number",
            "To serial number",
            "Total Number",
            "Cancelled",
            "Net issued"
          ],
          [client.gstin, "082026", "Custom invoice label", "TEST1", "TEST1", 1, 0, 1]
        )
      ])

    source = Path.join(tmp, "report.xlsx")
    File.write!(source, bytes)
    conn = log_in_user(conn, user)
    upload = %Plug.Upload{path: source, filename: "report.xlsx"}
    assert %{"ok" => true} = conn |> post(path, %{"file" => upload}) |> contract_response(200)
    %{"reports" => [report], "tasks" => tasks} = conn |> get(path) |> contract_response(200)
    workspace = conn |> get("/api/workspace/sales/#{client.id}/2026-08") |> contract_response(200)
    assert workspace["report_issue_count"] == length(tasks)
    assert length(workspace["exports"]["blockers"]) == length(tasks)
    refute Enum.find(workspace["exports"]["items"], &(&1["id"] == "json"))["enabled"]
    hsn = Enum.find(report["rows"], &(&1["section"] == "hsn_b2b"))
    assert hsn["values"]["rate"] == nil
    assert hsn["suggestion"]["values"]["rate"] == 18.0

    params = %{
      "dump_id" => report["dump_id"],
      "basis" => report["basis"],
      "sheet" => hsn["sheet"],
      "row" => hsn["row"],
      "values" => %{"rate" => 18}
    }

    for bad_values <- [
          %{"rate" => 180},
          %{"rate" => -18},
          %{"hsn_sc" => "bad"},
          %{"uqc" => "???"}
        ] do
      assert %{"error" => _} =
               conn |> patch(path, %{params | "values" => bad_values}) |> contract_response(422)
    end

    assert %{"ok" => true} = conn |> patch(path, params) |> contract_response(200)
    assert %{"error" => _} = conn |> patch(path, params) |> contract_response(422)
    {:ok, month} = Months.get_by_period(org.id, client.id, "2026-08")
    [corrected] = ReportImport.review(month)
    corrected_hsn = Enum.find(corrected["rows"], &(&1["section"] == "hsn_b2b"))
    assert corrected_hsn["values"]["rate"] == 18
    assert corrected_hsn["suggestion"] == nil
    assert corrected_hsn["cells"]["F"] in [nil, ""]
    assert %{"error" => _} = conn |> post(path, %{"file" => upload}) |> contract_response(422)
    %{user: other} = user_with_org_fixture()

    assert %{"error" => _} =
             conn |> recycle() |> log_in_user(other) |> get(path) |> contract_response(404)
  end

  @tag :tmp_dir
  test "grouped note corrections use the reviewed source set and cannot be replayed", %{
    conn: conn,
    tmp_dir: tmp
  } do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Nila.Clients.create_client(%{
        org_id: org.id,
        name: "Notes client",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    headers = [
      "GSTIN/UIN of Supplier",
      "Return Period",
      "Credit note/debit note / Refund Voucher Number",
      "Credit Note/Debit Note/ Refund Voucher date",
      "Total Note Value",
      "Rate",
      "Taxable Value",
      "IGST Amount",
      "Cess Amount",
      "CGST Amount",
      "SGST Amount",
      "Type",
      "Credit/debit note type/ Refund Voucher"
    ]

    rows =
      for number <- ["CN1", "CN2"],
          do: [
            client.gstin,
            "082026",
            number,
            "2026-08-01",
            118,
            18,
            100,
            0,
            0,
            9,
            9,
            "B2CL",
            "C"
          ]

    {:ok, bytes} = XlsxWriter.generate([sheet_rows("CDNUR", [headers | rows])])
    source = Path.join(tmp, "notes.xlsx")
    File.write!(source, bytes)
    conn = log_in_user(conn, user)
    path = "/api/workspace/sales/#{client.id}/2026-08/reports"

    assert %{"ok" => true} =
             conn
             |> post(path, %{"file" => %Plug.Upload{path: source, filename: "notes.xlsx"}})
             |> contract_response(200)

    %{"tasks" => tasks} = conn |> get(path) |> contract_response(200)
    task = Enum.find(tasks, &(&1["kind"] == "notes"))
    assert length(task["source_ids"]) == 2
    refute Enum.any?(tasks, &(&1["kind"] == "basis"))

    params =
      Map.take(task, ~w(dump_id basis sheet row source_ids))
      |> Map.put("values", %{"place_of_supply" => "33", "original_sale_category" => "b2cs"})

    assert %{"error" => _} =
             conn
             |> patch(path, Map.put(params, "source_ids", [hd(task["source_ids"])]))
             |> contract_response(422)

    assert %{"ok" => true} = conn |> patch(path, params) |> contract_response(200)
    assert %{"error" => _} = conn |> patch(path, params) |> contract_response(422)
    %{"tasks" => remaining} = conn |> get(path) |> contract_response(200)
    refute Enum.any?(remaining, &(&1["kind"] == "notes"))
    basis = Enum.find(remaining, &(&1["kind"] == "basis"))
    assert basis["amounts"]["notes"] == 200
    {:ok, month} = Months.get_by_period(org.id, client.id, "2026-08")
    invoices = Nila.Gst.Sales.Review.Resolutions.effective_workings(month).active_invoices
    assert length(invoices) == 2

    assert Enum.all?(
             invoices,
             &(&1["place_of_supply"] == "33" and &1["original_sale_category"] == "b2cs")
           )

    assert Enum.all?(invoices, &(&1["return_report_values"] |> hd() |> Map.get("pos") == nil))
  end

  defp sheet(name, headers, values), do: sheet_rows(name, [headers, values])

  defp sheet_rows(name, rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce(XlsxWriter.new_sheet(name), fn {row, r}, sheet ->
      row
      |> Enum.with_index()
      |> Enum.reduce(sheet, fn {value, c}, sheet -> XlsxWriter.write(sheet, r, c, value) end)
    end)
  end
end
