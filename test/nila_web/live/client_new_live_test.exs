defmodule NilaWeb.ClientNewLiveTest do
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Nila.Clients

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()
    %{conn: log_in_user(conn, user), org: org}
  end

  test "creates a client scoped to the org and redirects to the list", %{conn: conn, org: org} do
    {:ok, view, _html} = live(conn, ~p"/clients/new")

    assert has_element?(view, "#client-form")

    result =
      view
      |> form("#client-form", client: %{name: "Aurora Foods", type: "company"})
      |> render_submit()

    assert {:error, {:live_redirect, %{to: "/clients"}}} = result

    assert [client] = Clients.list_clients(org.id)
    assert client.name == "Aurora Foods"
    assert client.org_id == org.id

    {:ok, list_view, _html} = live(conn, ~p"/clients")
    assert render(list_view) =~ "Aurora Foods"
  end

  test "a blank name shows an error and creates nothing", %{conn: conn, org: org} do
    {:ok, view, _html} = live(conn, ~p"/clients/new")

    html =
      view
      |> form("#client-form", client: %{name: "", type: "company"})
      |> render_submit()

    assert html =~ "can&#39;t be blank"
    assert Clients.list_clients(org.id) == []
  end

  test "a bad GSTIN shows an error and creates nothing", %{conn: conn, org: org} do
    {:ok, view, _html} = live(conn, ~p"/clients/new")

    html =
      view
      |> form("#client-form",
        client: %{name: "Aurora Foods", type: "company", gstin: "NOTAGSTIN"}
      )
      |> render_submit()

    assert html =~ "is not a valid GSTIN"
    assert Clients.list_clients(org.id) == []
  end

  test "redirects logged-out visitors to log in" do
    assert {:error, {:redirect, %{to: "/users/log_in"}}} =
             live(Phoenix.ConnTest.build_conn(), ~p"/clients/new")
  end
end
