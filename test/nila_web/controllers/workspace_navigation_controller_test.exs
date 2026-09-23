defmodule NilaWeb.WorkspaceNavigationControllerTest do
  use NilaWeb.ConnCase, async: true
  import NilaWeb.ApiContract, only: [contract_response: 2]
  alias Nila.Clients

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()
    {:ok, client} = Clients.create_client(%{org_id: org.id, name: "Remember me", type: "company"})

    %{
      conn: log_in_user(conn, user),
      user: user,
      org: org,
      client: client,
      workspace: %{"clientId" => client.id, "period" => "2026-06", "section" => "purchases"}
    }
  end

  test "remembered workspace survives reload and controls server home and login", c do
    saved = put(c.conn, "/api/workspace/navigation", c.workspace)
    assert contract_response(saved, 200)["workspace"] == c.workspace
    assert get_session(saved, :current_client_id) == c.client.id
    assert saved.resp_cookies["nila_workspace"].http_only

    assert saved |> recycle() |> get("/api/workspace/navigation") |> contract_response(200) == %{
             "workspace" => c.workspace
           }

    assert saved |> recycle() |> get("/app") |> redirected_to() ==
             "/app/gst/#{c.client.id}/2026-06/purchases"

    assert saved |> recycle() |> get("/users/log_in") |> redirected_to() ==
             "/app/gst/#{c.client.id}/2026-06/purchases"

    # A new authentication session still reads the signed, user-scoped preference.
    login =
      saved
      |> recycle()
      |> Map.put(:secret_key_base, NilaWeb.Endpoint.config(:secret_key_base))
      |> init_test_session(%{})
      |> NilaWeb.UserAuth.log_in_user(c.user)

    assert redirected_to(login) == "/app/gst/#{c.client.id}/2026-06/purchases"
  end

  test "invalid selections cannot overwrite a valid workspace", c do
    saved = put(c.conn, "/api/workspace/navigation", c.workspace)

    for attrs <- [
          Map.put(c.workspace, "period", "2026-99"),
          Map.put(c.workspace, "section", "banking"),
          Map.put(c.workspace, "clientId", -1)
        ] do
      assert saved |> recycle() |> put("/api/workspace/navigation", attrs) |> response(422)
    end

    assert saved |> recycle() |> get("/api/workspace/navigation") |> contract_response(200) == %{
             "workspace" => c.workspace
           }
  end

  test "other users and firms never inherit the cookie", c do
    saved = put(c.conn, "/api/workspace/navigation", c.workspace)
    %{user: other} = user_with_org_fixture()
    other_conn = saved |> recycle() |> log_in_user(other)

    other_conn = get(other_conn, "/api/workspace/navigation")

    assert contract_response(other_conn, 200) == %{
             "workspace" => nil
           }

    assert other_conn
           |> recycle()
           |> put("/api/workspace/navigation", c.workspace)
           |> response(422)
  end

  test "removed client access restores no selection", c do
    saved = put(c.conn, "/api/workspace/navigation", c.workspace)
    Nila.Repo.delete!(c.client)

    assert saved |> recycle() |> get("/api/workspace/navigation") |> contract_response(200) == %{
             "workspace" => nil
           }

    assert saved |> recycle() |> get("/app") |> redirected_to() == "/app/clients"
  end

  test "legacy selection updates the same preference", c do
    path = "/gst/#{c.client.id}/2026-05/purchases"
    saved = post(c.conn, "/clients/#{c.client.id}/select", %{return_to: path})

    assert saved |> recycle() |> get("/api/workspace/navigation") |> contract_response(200) ==
             %{"workspace" => %{c.workspace | "period" => "2026-05"}}
  end

  test "anonymous callers cannot read or set navigation", c do
    assert build_conn() |> get("/api/workspace/navigation") |> response(401)
    assert build_conn() |> put("/api/workspace/navigation", c.workspace) |> response(401)
  end

  test "explicit page URLs replace memory for React and legacy handoffs", c do
    saved = put(c.conn, "/api/workspace/navigation", c.workspace)

    for prefix <- ["/app", ""] do
      visited = saved |> recycle() |> get("#{prefix}/gst/#{c.client.id}/2026-04/sales")

      assert visited |> recycle() |> get("/api/workspace/navigation") |> contract_response(200) ==
               %{"workspace" => %{c.workspace | "period" => "2026-04", "section" => "sales"}}
    end
  end
end
