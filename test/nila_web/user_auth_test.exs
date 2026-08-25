defmodule NilaWeb.UserAuthTest do
  use NilaWeb.ConnCase, async: true

  alias Nila.Accounts.Scope
  alias Nila.Clients
  alias NilaWeb.UserAuth

  test "fetch_current_scope_for_user assigns user and current org", %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{org_id: org.id, name: "Caltech", type: "company"})

    conn =
      conn
      |> log_in_user(user)
      |> UserAuth.fetch_current_scope_for_user([])

    assert %Scope{user: scoped_user, current_org: scoped_org, current_client: scoped_client} =
             conn.assigns.current_scope

    assert scoped_user.id == user.id
    assert scoped_org.id == org.id
    assert scoped_client.id == client.id
  end

  test "fetch_current_scope_for_user allows users without memberships", %{conn: conn} do
    user = user_fixture()

    conn =
      conn
      |> log_in_user(user)
      |> UserAuth.fetch_current_scope_for_user([])

    assert %Scope{user: scoped_user, current_org: nil} = conn.assigns.current_scope
    assert scoped_user.id == user.id
  end

  test "require_authenticated_user redirects anonymous users", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{})
      |> Phoenix.Controller.fetch_flash()
      |> UserAuth.require_authenticated_user([])

    assert conn.halted
    assert redirected_to(conn) == ~p"/users/log_in"
  end
end
