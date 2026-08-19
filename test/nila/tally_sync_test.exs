defmodule Nila.TallySyncTest do
  use Nila.DataCase, async: true

  import Nila.AccountsFixtures

  alias Nila.Clients
  alias Nila.Gst.Sales.{Month, Months}
  alias Nila.Repo
  alias Nila.TallyDevices
  alias Nila.TallyDevices.SyncedMaster
  alias Nila.TallySync

  test "reports referenced ledgers absent from the company snapshot case-insensitively" do
    %{org: org} = user_with_org_fixture()
    {:ok, device, _token} = TallyDevices.create_device(org, %{name: "Accounts PC"})
    {:ok, [company]} = TallyDevices.report_companies(device, [%{"name" => "Nila"}])
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert_all(SyncedMaster, [
      %{
        org_id: org.id,
        company_id: company.id,
        kind: "ledger",
        identity: "sales",
        name: "Sales",
        data: %{},
        inserted_at: now,
        updated_at: now
      }
    ])

    assert TallySync.missing_ledgers(company.id, ["sales", "Customer & Co", "Customer & Co"]) ==
             ["Customer & Co"]
  end

  test "a completed voucher sync opens the linked GST month and invalidates prior review" do
    %{org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "ABC Traders",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    {:ok, device, _token} = TallyDevices.create_device(org, %{name: "Accounts PC"})
    {:ok, [company]} = TallyDevices.report_companies(device, [%{"name" => "ABC Traders"}])
    company |> Ecto.Changeset.change(client_id: client.id) |> Repo.update!()

    {:ok, first_run} = TallySync.start(device, company.identity, ~D[2026-08-19])
    {:ok, _run} = TallySync.put_pipeline(device, first_run.id, :masters, [], true)

    {:ok, _run} =
      TallySync.put_pipeline(device, first_run.id, :vouchers, [voucher("INV-1")], true)

    assert {:ok, month} = Months.get_by_period(org.id, client.id, "2026-08")
    assert month.summary["tally_sync_id"] == first_run.id

    month |> Month.changeset(%{state: "reviewed"}) |> Repo.update!()

    {:ok, second_run} = TallySync.start(device, company.identity, ~D[2026-08-19])
    {:ok, _run} = TallySync.put_pipeline(device, second_run.id, :masters, [], true)

    {:ok, _run} =
      TallySync.put_pipeline(device, second_run.id, :vouchers, [voucher("INV-1")], true)

    assert {:ok, refreshed} = Months.get_by_period(org.id, client.id, "2026-08")
    assert refreshed.state == "worked"
    assert refreshed.summary["tally_sync_id"] == second_run.id
  end

  defp voucher(number) do
    %{
      "identity" => "guid:#{String.downcase(number)}",
      "date" => "2026-08-19",
      "voucher_type" => "Sales",
      "voucher_number" => number,
      "data" => %{"ledger_entries" => []}
    }
  end
end
