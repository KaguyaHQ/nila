defmodule Nila.Gst.Gstr1WorkerTest do
  use Nila.DataCase, async: true
  use Oban.Testing, repo: Nila.Repo

  import Nila.AccountsFixtures

  alias Nila.Clients
  alias Nila.Gst.Gstr1Worker
  alias Nila.Gst.SalesMonths
  alias Nila.Storage

  @period "2026-05"

  setup do
    %{org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Breeze Tech",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    pdf_key = "gstr1/#{org.id}/#{client.id}/#{@period}/source/bills.pdf"
    {:ok, _} = Storage.put(pdf_key, "%PDF-1.4 fake bytes")

    %{org: org, client: client, pdf_key: pdf_key}
  end

  test "produces a worked sales_month with a derived return and stored evidence", %{
    org: org,
    client: client,
    pdf_key: pdf_key
  } do
    assert :ok =
             perform_job(Gstr1Worker, %{
               "org_id" => org.id,
               "client_id" => client.id,
               "period" => @period,
               "pdf_key" => pdf_key
             })

    assert {:ok, month} = SalesMonths.get_by_period(org.id, client.id, @period)
    assert month.state == "worked"

    # Three stub invoices, derived into a portal-shaped return under the client's GSTIN.
    assert length(month.invoices) == 3
    assert month.derived_gstr1["gstin"] == "33AEWPH4158J1Z3"
    assert month.derived_gstr1["fp"] == "052026"
    assert month.summary["invoice_count"] == 3

    # The page-1 poison total must surface as an issue, never silently win.
    codes = Enum.map(month.issues, & &1["code"])
    assert "grand_total_mismatch" in codes

    # Evidence for a referenced page is stored and fetchable through the tenant guard.
    assert {:ok, bytes} = SalesMonths.fetch_evidence(org.id, client.id, @period, "page_01.png")
    assert byte_size(bytes) > 0
  end

  test "returns an error when the source PDF is missing", %{org: org, client: client} do
    assert {:error, _} =
             perform_job(Gstr1Worker, %{
               "org_id" => org.id,
               "client_id" => client.id,
               "period" => @period,
               "pdf_key" => "gstr1/#{org.id}/#{client.id}/#{@period}/source/missing.pdf"
             })
  end
end
