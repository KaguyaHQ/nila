defmodule NilaWeb.ClientContextControllerTest do
  use NilaWeb.ConnCase, async: true

  alias Nila.Clients

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, first} =
      Clients.create_client(%{org_id: org.id, name: "Breeze Tech", type: "company"})

    {:ok, second} =
      Clients.create_client(%{org_id: org.id, name: "Caltech", type: "company"})

    %{conn: log_in_user(conn, user), first: first, second: second}
  end

  test "stores the selected client and returns to the current work surface", %{
    conn: conn,
    second: second
  } do
    conn = post(conn, ~p"/clients/#{second.id}/select?return_to=/banking")

    assert redirected_to(conn) == ~p"/banking"
    assert get_session(conn, :current_client_id) == second.id
  end

  test "does not redirect outside Nila", %{conn: conn, second: second} do
    conn = post(conn, ~p"/clients/#{second.id}/select?return_to=//example.com")

    assert redirected_to(conn) == ~p"/sales-bills"
  end
end
