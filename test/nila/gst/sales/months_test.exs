defmodule Nila.Gst.Sales.MonthsTest do
  use Nila.DataCase, async: true

  import Nila.AccountsFixtures

  alias Nila.Clients
  alias Nila.Gst.Sales.Months, as: SalesMonths
  alias Nila.Storage

  @period "052026"

  setup do
    %{org: org} = user_with_org_fixture()
    {:ok, client} = Clients.create_client(%{org_id: org.id, name: "Breeze Tech", type: "company"})
    %{org: org, client: client}
  end

  describe "upsert/1 + get_by_period/3" do
    test "inserts then updates idempotently, scoped to the org", %{org: org, client: client} do
      attrs = %{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "worked",
        invoices: [%{"invoice_number" => "20/2026-27"}],
        derived_gstr1: %{"gstin" => "33AEWPH4158J1Z3"},
        issues: [%{"code" => "grand_total_mismatch"}],
        summary: %{"count" => 1}
      }

      assert {:ok, inserted} = SalesMonths.upsert(attrs)
      assert inserted.derived_gstr1["gstin"] == "33AEWPH4158J1Z3"

      assert {:ok, updated} =
               SalesMonths.upsert(%{attrs | summary: %{"count" => 2}, state: "reviewed"})

      assert updated.id == inserted.id
      assert updated.state == "reviewed"
      assert updated.summary["count"] == 2

      assert {:ok, fetched} = SalesMonths.get_by_period(org.id, client.id, @period)
      assert fetched.id == inserted.id
    end

    test "another org cannot read this org's month", %{client: client} do
      %{org: other_org} = user_with_org_fixture()

      {:ok, _} =
        SalesMonths.upsert(%{
          org_id: client.org_id,
          client_id: client.id,
          period: @period,
          state: "worked"
        })

      assert {:error, :not_found} =
               SalesMonths.get_by_period(other_org.id, client.id, @period)
    end
  end

  describe "list_for_org/1" do
    test "returns only the org's months, newest period first", %{org: org, client: client} do
      for period <- ["012026", "052026"] do
        {:ok, _} =
          SalesMonths.upsert(%{
            org_id: org.id,
            client_id: client.id,
            period: period,
            state: "worked"
          })
      end

      periods = org.id |> SalesMonths.list_for_org() |> Enum.map(& &1.period)
      assert periods == ["052026", "012026"]
    end
  end

  describe "fetch_evidence/4" do
    test "serves bytes only after proving the month belongs to the org", %{
      org: org,
      client: client
    } do
      {:ok, _} =
        SalesMonths.upsert(%{
          org_id: org.id,
          client_id: client.id,
          period: @period,
          state: "worked"
        })

      key = SalesMonths.evidence_key(org.id, client.id, @period, "page_01.png")
      {:ok, _} = Storage.put(key, <<1, 2, 3>>)

      assert {:ok, <<1, 2, 3>>} =
               SalesMonths.fetch_evidence(org.id, client.id, @period, "page_01.png")

      # Path traversal is rejected before any storage read.
      assert {:error, :not_found} =
               SalesMonths.fetch_evidence(org.id, client.id, @period, "../secret.png")

      # A foreign org cannot fetch, even with a valid basename.
      %{org: other_org} = user_with_org_fixture()

      assert {:error, :not_found} =
               SalesMonths.fetch_evidence(other_org.id, client.id, @period, "page_01.png")
    end
  end
end
