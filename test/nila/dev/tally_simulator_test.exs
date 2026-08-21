defmodule Nila.Dev.TallySimulatorTest do
  use Nila.DataCase, async: false

  import Nila.AccountsFixtures

  alias Nila.Dev.TallySimulator
  alias Nila.TallyDevices
  alias Nila.TallyJobs
  alias NilaWeb.Presence

  test "stands in for an open Tally company and completes voucher imports" do
    %{org: org} = user_with_org_fixture()

    simulator =
      start_supervised!(
        {TallySimulator, company_name: "Breeze Tech", gstin: "33AEWPH4158J1Z3", org_ids: [org.id]}
      )

    assert :ok = TallySimulator.sync(simulator)
    assert [company] = TallyDevices.list_open_companies(org.id)
    assert company.name == "Breeze Tech"
    assert company.gstin == "33AEWPH4158J1Z3"

    assert %{metas: [%{connector_version: "development"}]} =
             Presence.get_by_key(
               "tally_devices:#{org.id}",
               Integer.to_string(company.device_id)
             )

    assert {:ok, job, :created} =
             TallyJobs.enqueue_import_vouchers(company, "<ENVELOPE/>", 11,
               source_key: "development:test"
             )

    assert :ok = TallySimulator.drain(simulator)
    completed = TallyJobs.get_job!(job.id)

    assert completed.status == "succeeded"
    assert completed.result["created"] == 11
    assert completed.result["errors"] == 0
  end
end
