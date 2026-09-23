defmodule NilaWeb.Gst.PurchaseClaimGroupTest do
  use NilaWeb.ConnCase, async: true
  import Nila.GstFixtures
  alias Nila.Accounts.Scope
  alias Nila.Gst.Purchase.{ItcCases, ItcDecisions, Months, Reconciliation, Register}
  alias NilaWeb.Gst.PurchaseWorkspace

  test "an excluded invoice stays visible after books introduce an ambiguous group",
       %{
         conn: conn
       } do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Nila.Clients.create_client(%{
        org_id: org.id,
        name: "Purchase ambiguity QA",
        gstin: "33AEWPH4158J1Z3",
        type: "company"
      })

    scope = Scope.for_user(user)
    portal = [invoice(nil, "PORTAL-A"), invoice(nil, "PORTAL-B")]
    gstr2b_arrived!(org, client, "2026-08", portal)
    month = put_month(org, client, [], portal)
    excluded = Enum.find(ItcCases.list_for_month(month), &(&1.invoice_number == "PORTAL-A"))

    assert {:ok, _} =
             ItcDecisions.apply(scope, client.id, "2026-08", [excluded.case_id], %{
               "choice" => "exclude",
               "exclude_reason" => "personal",
               "note" => "Personal use"
             })

    _month = put_month(org, client, [invoice("book-1", "BOOK-X")], portal)
    assert {:ok, workspace} = PurchaseWorkspace.load(scope, client.id, "2026-08")
    group = Enum.find(workspace.items, &(length(&1.counterparts) == 2))
    assert group
    refute group.selectable?
    assert group.treatment_case_ids != []

    body =
      conn
      |> log_in_user(user)
      |> get("/api/workspace/purchases/#{client.id}/2026-08?filter=gstr2b&q=PORTAL-A")
      |> json_response(200)

    assert Enum.any?(body["rows"], &(&1["number"] == "PORTAL-A"))
    assert {:ok, updated} = PurchaseWorkspace.load(scope, client.id, "2026-08")
    group = Enum.find(updated.items, &(length(&1.counterparts) == 2))
    assert excluded.case_id in group.treatment_case_ids
    assert length(Nila.Gst.Purchase.Workings.gstr2b_invoices(updated.workings.recon)) == 2
    assert length(Nila.Gst.Purchase.Workings.books_invoices(updated.workings.recon)) == 1
  end

  test "credit carried into a month without imports can be treated", %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Nila.Clients.create_client(%{
        org_id: org.id,
        name: "Carry QA",
        gstin: "33AEWPH4158J1Z3",
        type: "company"
      })

    scope = Scope.for_user(user)
    portal = [invoice(nil, "CARRY-1")]
    gstr2b_arrived!(org, client, "2026-08", portal)
    month = put_month(org, client, [], portal)
    case_id = hd(ItcCases.list_for_month(month)).case_id

    assert {:ok, _} =
             ItcDecisions.apply(scope, client.id, "2026-08", [case_id], %{
               "choice" => "later",
               "later_reason" => "review_pending"
             })

    assert {:ok, _} =
             Nila.Gst.Purchase.Resolutions.record_itc_case_event_and_refresh(
               month,
               case_id,
               "document_not_held",
               [],
               user.id
             )

    assert {:ok, _} = Nila.Gst.Filing.Signoffs.sign_off(month, scope)

    assert {:ok, _} = ItcDecisions.record_document(scope, client.id, "2026-09", case_id)

    assert {:ok, _} =
             ItcDecisions.apply(scope, client.id, "2026-09", [case_id], %{"choice" => "claim"})

    body =
      conn
      |> log_in_user(user)
      |> get("/api/workspace/purchases/#{client.id}/2026-09?filter=all")
      |> json_response(200)

    assert Enum.any?(body["carried"], &(&1["treatment"] == "Claim this month"))
    assert {:ok, _} = PurchaseWorkspace.load(scope, client.id, "2026-09")
  end

  defp invoice(id, number) do
    %{
      "id" => id,
      "vendor_name" => "Sharma Steels",
      "vendor_gstin" => "33AALCP2218B1ZX",
      "invoice_number" => number,
      "invoice_date" => "2026-08-05",
      "taxable_paise" => 100_000,
      "tax_paise" => %{"cgst" => 9_000, "sgst" => 9_000, "igst" => 0},
      "total_paise" => 118_000,
      "images" => []
    }
  end

  defp put_month(org, client, books, portal) do
    recon = Reconciliation.reconcile(books, portal)
    rows = Register.rows(books, recon, %{})

    {:ok, month} =
      Months.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: "2026-08",
        state: "worked",
        recon: recon,
        register_rows: rows,
        summary: Register.summary(rows)
      })

    month
  end
end
