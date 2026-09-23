defmodule NilaWeb.GstConnectionControllerTest do
  use NilaWeb.ConnCase, async: false
  import NilaWeb.ApiContract, only: [contract_response: 2]
  alias Nila.{Clients, Repo}
  alias Nila.Gst.Portal
  alias Nila.Integrations.Whitebooks

  setup %{conn: conn} do
    previous = Application.get_env(:nila, Whitebooks)

    Application.put_env(:nila, Whitebooks,
      client_id: "test",
      client_secret: "secret",
      email: "test@example.test",
      ip_address: "203.0.113.1",
      req_options: [plug: {Req.Test, Whitebooks}]
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:nila, Whitebooks, previous),
        else: Application.delete_env(:nila, Whitebooks)
    end)

    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Notice client",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    %{conn: log_in_user(conn, user), user: user, org: org, client: client}
  end

  defp connection_path(client), do: "/api/workspace/clients/#{client.id}/gst-connection"

  test "connection state excludes credentials and rejects missing GSTIN", %{
    conn: conn,
    client: client,
    org: org
  } do
    body = conn |> get(connection_path(client)) |> contract_response(200)
    assert body == %{"state" => "not_connected", "username" => "", "can_connect" => true}
    {:ok, blank} = Clients.create_client(%{org_id: org.id, name: "Blank", type: "company"})

    assert (conn |> get(connection_path(blank)) |> contract_response(200))["state"] ==
             "missing_gstin"

    assert conn
           |> post(connection_path(blank) <> "/otp", %{username: "x"})
           |> contract_response(422)
  end

  test "verification connects without creating fetch jobs and records provider expiry", %{
    conn: conn,
    client: client,
    org: org
  } do
    before_jobs = Repo.aggregate(Oban.Job, :count)

    Req.Test.expect(Whitebooks, fn request ->
      Req.Test.json(request, %{"status_cd" => "1", "txn" => "secret-transaction"})
    end)

    body =
      conn
      |> post(connection_path(client) <> "/otp", %{username: "gst-user"})
      |> contract_response(200)

    refute body["challenge"] =~ "secret-transaction"
    token = body["challenge"]

    {:ok, other} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Other",
        type: "company",
        gstin: client.gstin
      })

    assert conn
           |> post(connection_path(other) <> "/verify", %{challenge: token, otp: "123456"})
           |> contract_response(422)

    assert conn
           |> post(connection_path(client) <> "/verify", %{challenge: "bad", otp: "123456"})
           |> contract_response(422)

    Req.Test.expect(Whitebooks, fn request -> Req.Test.json(request, %{"status_cd" => "1"}) end)

    body =
      conn
      |> post(connection_path(client) <> "/verify", %{challenge: token, otp: "123456"})
      |> contract_response(200)

    assert body == %{"state" => "connected", "username" => "gst-user", "can_connect" => true}
    assert Repo.aggregate(Oban.Job, :count) == before_jobs
    {:ok, connection} = Portal.connection(org.id, client.id)

    connection
    |> Ecto.Changeset.change(
      credentials: Map.put(connection.credentials, "reauth_required", true)
    )
    |> Repo.update!()

    assert (conn |> get(connection_path(client)) |> contract_response(200))["state"] == "expired"
    {:ok, _} = Clients.update_client(client, %{gstin: nil})

    assert (conn |> get(connection_path(client)) |> contract_response(200))["state"] ==
             "missing_gstin"
  end

  test "scope and connector permission guard every action", %{conn: conn, client: client} do
    %{user: viewer, org: viewer_org} = user_with_org_fixture(%{role: "viewer"})

    {:ok, own} =
      Clients.create_client(%{
        org_id: viewer_org.id,
        name: "Viewer client",
        type: "company",
        gstin: client.gstin
      })

    viewer_conn = log_in_user(build_conn(), viewer)
    refute (viewer_conn |> get(connection_path(own)) |> contract_response(200))["can_connect"]
    assert conn |> get(connection_path(own)) |> contract_response(404)

    for action <- ["otp", "verify"] do
      assert viewer_conn
             |> post(connection_path(own) <> "/" <> action, %{})
             |> contract_response(403)

      assert conn |> post(connection_path(own) <> "/" <> action, %{}) |> contract_response(404)
    end

    assert build_conn() |> get(connection_path(client)) |> contract_response(401)
    assert conn |> get("/api/workspace/clients/nope/gst-connection") |> contract_response(404)
  end
end
