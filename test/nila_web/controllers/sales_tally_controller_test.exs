defmodule NilaWeb.SalesTallyControllerTest do
  use NilaWeb.ConnCase, async: true
  import NilaWeb.ApiContract, only: [contract_response: 2]
  alias Nila.{Clients, Repo, TallyDevices}

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Sales client",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    %{conn: log_in_user(conn, user), org: org, client: client}
  end

  test "GST-only clients have no Tally fields or required setup", c do
    body =
      c.conn |> get("/api/workspace/sales/#{c.client.id}/2026-08/tally") |> contract_response(200)

    assert body == %{"enabled" => false}
  end

  test "selected month refresh sends a read-only request to the connected connector", c do
    {:ok, device, _} = TallyDevices.create_device(c.org, %{name: "Accounts"})

    {:ok, [company]} =
      TallyDevices.report_companies(device, [
        %{"name" => "Breeze", "tally_guid" => "test-guid", "gstin" => c.client.gstin}
      ])

    c.client |> Ecto.Changeset.change(active_tally_company_id: company.id) |> Repo.update!()

    {:ok, _} =
      NilaWeb.Presence.track(self(), "tally_devices:#{c.org.id}", Integer.to_string(device.id), %{
        device_id: device.id
      })

    Phoenix.PubSub.subscribe(Nila.PubSub, Nila.TallyJobs.device_topic(device.id))

    body =
      c.conn
      |> post("/api/workspace/sales/#{c.client.id}/2026-08/tally/sync", %{})
      |> contract_response(200)

    assert body["sync"]["status"] == "running"
    assert body["sync"]["period_start"] == "2025-08-01"
    assert body["sync"]["period_end"] == "2026-08-31"

    assert_receive {:tally_sync_requested,
                    %{
                      id: run_id,
                      company_identity: "guid:test-guid",
                      period_start: "2025-08-01",
                      period_end: "2026-08-31"
                    }}

    assert run_id == body["sync"]["run_id"]
    assert Repo.aggregate(Nila.TallyJobs.Job, :count) == 0
    refute body["can_post"]
  end

  test "offline connectors return a useful error without creating a sync run", c do
    {:ok, device, _} = TallyDevices.create_device(c.org, %{name: "Accounts"})
    {:ok, [company]} = TallyDevices.report_companies(device, [%{"name" => "Breeze"}])
    c.client |> Ecto.Changeset.change(active_tally_company_id: company.id) |> Repo.update!()

    body =
      c.conn
      |> post("/api/workspace/sales/#{c.client.id}/2026-08/tally/sync", %{})
      |> contract_response(409)

    assert body["error"] =~ "Open Nila Connector"
    assert Repo.aggregate(Nila.TallyDevices.SyncRun, :count) == 0
  end

  test "linked company response follows the generated API contract", c do
    {:ok, device, _} = TallyDevices.create_device(c.org, %{name: "Accounts"})

    {:ok, [company]} =
      TallyDevices.report_companies(device, [%{"name" => "Breeze", "gstin" => c.client.gstin}])

    c.client |> Ecto.Changeset.change(active_tally_company_id: company.id) |> Repo.update!()

    body =
      c.conn |> get("/api/workspace/sales/#{c.client.id}/2026-08/tally") |> contract_response(200)

    assert body["enabled"]
    assert body["company"]["id"] == company.id
    assert body["proposals"] == []
    refute body["can_post"]
  end

  test "another firm's client is unavailable", c do
    %{org: other} = user_with_org_fixture()

    {:ok, foreign} =
      Clients.create_client(%{org_id: other.id, name: "Other client", type: "company"})

    assert c.conn
           |> get("/api/workspace/sales/#{foreign.id}/2026-08/tally")
           |> contract_response(404)
  end

  test "anonymous requests cannot inspect proposed vouchers" do
    assert build_conn() |> get("/api/workspace/sales/1/2026-08/tally") |> contract_response(401)
  end
end
