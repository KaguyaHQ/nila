defmodule NilaWeb.ClientsLiveTest do
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Nila.Clients

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()
    %{conn: log_in_user(conn, user), org: org}
  end

  test "lists only client identity", %{conn: conn, org: org} do
    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Breeze Tech",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    {:ok, view, _html} = live(conn, ~p"/clients")

    assert has_element?(view, "#clients-table", "Breeze Tech")
    assert has_element?(view, "#clients-table", "33AEWPH4158J1Z3")
    assert has_element?(view, "#client-#{client.id} a[href='/clients/#{client.id}/edit']")

    html = render(view)
    refute html =~ "Tally company"
    refute html =~ "Not connected"
    refute html =~ "Latest month"
    refute html =~ "Needs a decision"
    refute html =~ "Collecting documents"
    refute html =~ ">Type<"
  end

  test "shows an empty state when the org has no clients", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/clients")

    assert has_element?(view, "#clients-empty", "No clients yet.")
    assert has_element?(view, "#clients-add-first", "Add your first client")
  end

  test "does not list another org's clients", %{conn: conn} do
    %{org: other_org} = user_with_org_fixture(%{org: %{gstin: "27ABCDE1234F1Z0"}})

    {:ok, _other} =
      Clients.create_client(%{org_id: other_org.id, name: "Rival Corp", type: "company"})

    {:ok, view, _html} = live(conn, ~p"/clients")

    refute render(view) =~ "Rival Corp"
  end

  test "redirects logged-out visitors to log in" do
    assert {:error, {:redirect, %{to: "/users/log_in"}}} =
             live(Phoenix.ConnTest.build_conn(), ~p"/clients")
  end
end
