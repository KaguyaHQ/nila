defmodule NilaWeb.PurchaseWorkspaceControllerTest do
  import NilaWeb.ApiContract, only: [contract_response: 2]
  use NilaWeb.ConnCase, async: true
  import Nila.GstFixtures
  import Ecto.Query
  alias Nila.Gst.Purchase.{Months, Reconciliation, Register, Resolutions}
  alias Nila.Repo

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Nila.Clients.create_client(%{
        org_id: org.id,
        name: "Purchase API",
        gstin: "33AEWPH4158J1Z3",
        type: "company"
      })

    %{
      conn: log_in_user(conn, user),
      user: user,
      org: org,
      client: client,
      path: "/api/workspace/purchases/#{client.id}/2026-08"
    }
  end

  test "empty client month has honest input states and full-page source actions", c do
    response = get(c.conn, c.path)
    body = contract_response(response, 200)
    assert body["client"]["id"] == c.client.id
    assert body["month_label"] == "August 2026"
    assert body["rows"] == []
    refute body["inputs"]["books"]["present"]
    refute body["inputs"]["portal"]["present"]
    refute body["overview"]["complete"]
    refute body["working"]["enabled"]
    assert body["links"]["import_excel"] == "/gst/#{c.client.id}/2026-08/purchases/import-excel"
    assert get_resp_header(response, "cache-control") == ["private, no-store"]
  end

  test "source counts differ from review groups; filters preserve exact source links", c do
    books = [invoice("A", "SHARED", 90_000), invoice("B", "SHARED", 90_000)]
    seed(c, books, [invoice(nil, "SHARED", 90_000)])
    body = c.conn |> get(c.path) |> contract_response(200)
    assert body["inputs"]["books"]["count"] == 2
    assert body["inputs"]["portal"]["count"] == 1
    assert length(body["rows"]) == 2

    assert Enum.all?(
             body["rows"],
             &String.starts_with?(
               &1["review_url"],
               "/gst/#{c.client.id}/2026-08/purchases/review/"
             )
           )

    filtered = c.conn |> get(c.path, %{filter: "gstr2b", q: "shared"}) |> contract_response(200)
    assert length(filtered["rows"]) == 1
    assert hd(filtered["rows"])["review_url"] =~ "filter=gstr2b"
    assert hd(filtered["rows"])["review_url"] =~ "q=shared"
    assert (c.conn |> get(c.path, %{q: "absent"}) |> contract_response(200))["rows"] == []
  end

  test "2B-only month does not claim reconciliation is complete", c do
    seed(c, [], [invoice(nil, "PORTAL", 90_000)])
    body = c.conn |> get(c.path, %{filter: "gstr2b"}) |> contract_response(200)
    refute body["overview"]["comparison_available"]
    refute body["overview"]["complete"]
    assert body["inputs"]["portal"]["present"]
    assert body["notice"] =~ "Books comparison is not available"
    assert length(body["rows"]) == 1
  end

  test "source tax preserves cess and credit-note direction without treating matching as claimed",
       c do
    row =
      invoice("CREDIT", "CN-1", 10_000)
      |> Map.put("document_type", "credit_note")
      |> Map.put("tax_paise", %{"cgst" => 10_000, "sgst" => 10_000, "igst" => 0, "cess" => 5_000})

    seed(c, [row], [Map.delete(row, "id")])
    body = c.conn |> get(c.path) |> contract_response(200)
    expected = NilaWeb.Gst.PurchaseWorkspace.money(-25_000)
    assert body["inputs"]["books"]["tax"] == expected
    assert hd(body["rows"])["tax"] == expected
    assert hd(body["rows"])["document_type"] == "credit_note"
    assert body["overview"]["itc"]["claim"] == NilaWeb.Gst.PurchaseWorkspace.money(0)
  end

  test "mismatch remains reviewable and draft workbook remains available", c do
    seed(c, [invoice("A", "INV-1", 90_000)], [invoice(nil, "INV-1", 95_000)])
    body = c.conn |> get(c.path, %{filter: "mismatch"}) |> contract_response(200)
    assert length(body["rows"]) == 1
    assert body["overview"]["remaining"] > 0
    refute body["overview"]["complete"]
    assert body["working"]["enabled"]
    assert body["working"]["status"] == "Draft working"
    assert c.conn |> get(body["working"]["url"]) |> response(200)
  end

  test "recorded snapshot values and readonly state survive new current projections", c do
    month = seed(c, [], [])
    workings = Resolutions.workings(month)

    Repo.insert!(%Nila.Gst.Filing.Signoff{
      org_id: c.org.id,
      client_month_id: month.id,
      signed_by_id: c.user.id,
      snapshot: %{
        "rows" => [],
        "summary" => workings.summary,
        "gstr3b" => workings.gstr3b,
        "itc" => Map.put(workings.itc, "current_claim_paise", 987_654),
        "case_lines" => [],
        "review" => %{
          "recon" => %{},
          "baseline" => %{},
          "decisions" => %{},
          "accepted_reasons" => %{},
          "gstr2b_decisions" => %{}
        }
      }
    })

    body = c.conn |> get(c.path) |> contract_response(200)
    assert body["signed_off"]
    refute body["can_edit"]
    assert body["overview"]["itc"]["claim"] == NilaWeb.Gst.PurchaseWorkspace.money(987_654)
    assert body["working"]["status"] == "Recorded sign-off snapshot"
  end

  test "tenant, session, invalid input and viewer rules", c do
    assert c.conn |> get(c.path, %{q: %{bad: "shape"}}) |> contract_response(400)
    %{user: other} = user_with_org_fixture()
    assert build_conn() |> log_in_user(other) |> get(c.path) |> contract_response(404)
    assert build_conn() |> get(c.path) |> contract_response(401)
    assert c.conn |> get(String.replace(c.path, "2026-08", "2026-99")) |> contract_response(400)

    Repo.update_all(
      from(m in Nila.Orgs.Membership, where: m.user_id == ^c.user.id and m.org_id == ^c.org.id),
      set: [role: "viewer"]
    )

    seed(c, [invoice("A", "INV-1", 90_000)], [])
    body = c.conn |> get(c.path) |> contract_response(200)
    refute body["can_edit"]
    assert body["working"]["enabled"]
  end

  defp invoice(id, number, tax),
    do: %{
      "id" => id,
      "vendor_name" => "Sharma Steels",
      "vendor_gstin" => "33AALCP2218B1ZX",
      "invoice_number" => number,
      "invoice_date" => "2026-08-05",
      "taxable_paise" => 1_000_000,
      "tax_paise" => %{"cgst" => tax, "sgst" => tax, "igst" => 0},
      "total_paise" => 1_000_000 + tax * 2,
      "images" => []
    }

  defp seed(c, books, portal) do
    gstr2b_arrived!(c.org, c.client, "2026-08", portal)
    recon = Reconciliation.reconcile(books, portal)
    rows = Register.rows(books, recon, %{})

    {:ok, month} =
      Months.upsert(%{
        org_id: c.org.id,
        client_id: c.client.id,
        period: "2026-08",
        state: "worked",
        recon: recon,
        register_rows: rows,
        summary: Register.summary(rows)
      })

    month
  end
end
