defmodule NilaWeb.Gst.PurchaseClaimGroupTest do
  use NilaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Nila.GstFixtures
  alias Nila.Accounts.Scope
  alias Nila.Gst.Purchase.{ItcCases, ItcDecisions, Months, Reconciliation, Register}
  alias NilaWeb.Gst.PurchaseWorkspace

  test "an exclusion stays visible and can be cleared after books introduce an ambiguous group",
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
             ItcDecisions.exclude(scope, client.id, "2026-08", [excluded.case_id], "Personal use")

    month = put_month(org, client, [invoice("book-1", "BOOK-X")], portal)
    assert {:ok, workspace} = PurchaseWorkspace.load(scope, client.id, "2026-08")
    group = Enum.find(workspace.items, &(length(&1.counterparts) == 2))
    assert group
    refute group.selectable?
    assert group.claim_state == "not_claiming"
    assert group.claim_reason == "PORTAL-A: Personal use"
    assert [%{case_id: case_id, claim_reason: "Personal use"}] = group.claim_exclusions
    assert case_id == excluded.case_id

    path = "/gst/#{client.id}/2026-08/purchases?filter=not_claiming&q="
    {:ok, view, _} = live(log_in_user(conn, user), path)
    assert has_element?(view, "#purchase-claim-state-#{group.id}", "Not claiming")
    assert has_element?(view, "#purchase-items", "PORTAL-A: Personal use")
    refute has_element?(view, "#purchase-select-#{group.id}")

    view
    |> element("#purchase-reopen-case-#{group.id}-#{excluded.case_id}")
    |> render_click()

    refute has_element?(view, "#purchase-claim-state-#{group.id}")
    assert {:ok, updated} = PurchaseWorkspace.load(scope, client.id, "2026-08")
    group = Enum.find(updated.items, &(length(&1.counterparts) == 2))
    assert group.claim_exclusions == []
    assert is_nil(group.claim_state)
    assert Enum.all?(ItcCases.list_for_month(month), &is_nil(&1.claim_state))
    assert length(Nila.Gst.Purchase.Workings.gstr2b_invoices(updated.workings.recon)) == 2
    assert length(Nila.Gst.Purchase.Workings.books_invoices(updated.workings.recon)) == 1
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
