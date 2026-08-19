defmodule NilaWeb.TallyPairingControllerTest do
  use NilaWeb.ConnCase, async: true

  import Nila.AccountsFixtures

  alias Nila.Accounts.Scope
  alias Nila.TallyDevices

  test "creates a no-store pairing and exchanges it after browser approval", %{conn: conn} do
    conn =
      post(conn, ~p"/api/tally/pairings", %{
        "device_name" => "Accounts PC",
        "connector_version" => "0.1.0"
      })

    assert %{
             "device_code" => device_code,
             "verification_url" => verification_url,
             "expires_in" => 600,
             "retry_after" => 2
           } = json_response(conn, 201)

    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert verification_url =~ "/settings/connectors/tally/pair/"
    approval_code = verification_url |> URI.parse() |> Map.fetch!(:path) |> Path.basename()

    pending_conn =
      post(build_conn(), ~p"/api/tally/pairings/exchange", %{device_code: device_code})

    assert %{"status" => "pending"} = json_response(pending_conn, 202)

    %{user: user} = user_with_org_fixture()

    assert {:ok, _pairing} =
             TallyDevices.approve_pairing(approval_code, Scope.for_user(user))

    linked_conn =
      post(build_conn(), ~p"/api/tally/pairings/exchange", %{device_code: device_code})

    assert %{
             "status" => "linked",
             "device_id" => device_id,
             "device_token" => ^device_code,
             "websocket_url" => websocket_url
           } = json_response(linked_conn, 200)

    assert is_integer(device_id)
    assert websocket_url == "ws://localhost:4000/connector/websocket?vsn=2.0.0"
    assert get_resp_header(linked_conn, "cache-control") == ["no-store"]

    repeated_conn =
      post(build_conn(), ~p"/api/tally/pairings/exchange", %{device_code: device_code})

    assert %{"device_id" => ^device_id, "device_token" => ^device_code} =
             json_response(repeated_conn, 200)
  end

  test "rejects malformed pairing requests", %{conn: conn} do
    conn = post(conn, ~p"/api/tally/pairings", %{"device_name" => String.duplicate("x", 121)})
    assert %{"error" => "invalid_request"} = json_response(conn, 422)
  end

  test "a linked device can revoke its own credential", %{conn: conn} do
    %{org: org} = user_with_org_fixture()
    assert {:ok, device, token} = TallyDevices.create_device(org, %{name: "Accounts PC"})

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> delete(~p"/api/tally/device")

    assert response(conn, 204)
    assert is_nil(TallyDevices.authenticate_device(token))
    assert Nila.Repo.reload!(device).revoked_at
  end

  test "rejects device revocation without a valid bearer credential", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer invalid")
      |> delete(~p"/api/tally/device")

    assert %{"error" => "invalid_device"} = json_response(conn, 401)
  end

  test "Phoenix filters every pairing credential field" do
    assert %{
             "device_code" => "[FILTERED]",
             "approval_code" => "[FILTERED]",
             "device_token" => "[FILTERED]",
             "harmless" => "visible"
           } =
             Phoenix.Logger.filter_values(%{
               "device_code" => "device-secret",
               "approval_code" => "approval-secret",
               "device_token" => "permanent-secret",
               "harmless" => "visible"
             })
  end
end
