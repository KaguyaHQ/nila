defmodule NilaWeb.TallySyncControllerTest do
  use NilaWeb.ConnCase, async: true

  import Nila.AccountsFixtures

  alias Nila.Repo
  alias Nila.TallyDevices
  alias Nila.TallyDevices.{SyncRun, SyncedMaster, SyncedVoucher}

  test "a device syncs masters then current-period vouchers with independent status", %{
    conn: conn
  } do
    %{org: org} = user_with_org_fixture()
    {:ok, device, token} = TallyDevices.create_device(org, %{name: "Accounts PC"})

    assert {:ok, [_company]} =
             TallyDevices.report_companies(device, [
               %{"name" => "Nila", "tally_guid" => "company-guid"}
             ])

    conn = authorize(conn, token)

    start_conn =
      post(conn, ~p"/api/tally/syncs", %{company_identity: "guid:company-guid"})

    assert %{
             "id" => run_id,
             "status" => "running",
             "masters_status" => "pending",
             "vouchers_status" => "pending",
             "period_start" => period_start,
             "period_end" => period_end
           } = json_response(start_conn, 201)

    masters_conn =
      conn
      |> recycle()
      |> authorize(token)
      |> put(~p"/api/tally/syncs/#{run_id}/masters", %{
        complete: true,
        records: [
          %{
            kind: "ledger",
            identity: "guid:cash",
            name: "Cash",
            tally_guid: "cash",
            alter_id: "12",
            data: %{parent: "Cash-in-Hand"}
          }
        ]
      })

    assert %{"masters_status" => "succeeded", "status" => "running", "masters_count" => 1} =
             json_response(masters_conn, 200)

    vouchers_conn =
      conn
      |> recycle()
      |> authorize(token)
      |> put(~p"/api/tally/syncs/#{run_id}/vouchers", %{
        complete: true,
        records: [
          %{
            identity: "guid:voucher-1",
            master_id: 42,
            tally_guid: "voucher-1",
            date: period_end,
            voucher_type: "Sales",
            voucher_number: "1",
            data: %{ledger_entries: []}
          }
        ]
      })

    assert %{
             "status" => "succeeded",
             "vouchers_status" => "succeeded",
             "vouchers_count" => 1
           } = json_response(vouchers_conn, 200)

    assert Repo.aggregate(SyncedMaster, :count) == 1
    assert Repo.aggregate(SyncedVoucher, :count) == 1
    assert Repo.get!(SyncRun, run_id).completed_at
    assert Date.from_iso8601!(period_start) == Date.beginning_of_month(Date.utc_today())
  end

  test "rejects a sync without a device credential", %{conn: conn} do
    conn = post(conn, ~p"/api/tally/syncs", %{company_identity: "guid:any"})
    assert %{"error" => "invalid_device"} = json_response(conn, 401)
  end

  defp authorize(conn, token),
    do: put_req_header(conn, "authorization", "Bearer #{token}")
end
