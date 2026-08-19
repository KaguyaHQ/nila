defmodule Nila.TallySyncTest do
  use Nila.DataCase, async: true

  import Nila.AccountsFixtures

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
end
