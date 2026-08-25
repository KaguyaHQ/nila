defmodule NilaWeb.ClientNewLiveTest do
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Nila.Clients
  alias Nila.TallyDevices

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()
    %{conn: log_in_user(conn, user), org: org}
  end

  test "creates a client manually and returns to the directory", %{conn: conn, org: org} do
    {:ok, view, _html} = live(conn, ~p"/clients/new")

    assert has_element?(view, "#client-form")

    result =
      view
      |> form("#client-form", client: %{name: "Aurora Foods"})
      |> render_submit()

    assert [client] = Clients.list_clients(org.id)
    assert client.name == "Aurora Foods"
    assert client.org_id == org.id
    assert client.type == "company"
    assert client.chase_channel == "none"

    assert {:error, {:live_redirect, %{to: "/clients"}}} = result

    {:ok, directory, html} = follow_redirect(result, conn)
    assert html =~ "Aurora Foods added."
    assert has_element?(directory, "#clients-table", "Aurora Foods")
  end

  test "shows only the client details needed at creation", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/clients/new")

    assert has_element?(view, "#client-new-page h1", "Add client")
    assert has_element?(view, "#client_name")
    assert has_element?(view, "#client_gstin")
    refute has_element?(view, "#client_tally_company_id")
    refute has_element?(view, "#client_email")
    refute has_element?(view, "#client_phone")
    refute has_element?(view, "#client_type")
    refute has_element?(view, "#client_pan")
    refute has_element?(view, "#client_chase_channel")
    refute render(view) =~ "A first-class party"
  end

  test "connects the new client to a selected Tally company", %{conn: conn, org: org} do
    {:ok, device, _token} = TallyDevices.create_device(org, %{name: "Accounts PC"})

    {:ok, [company]} =
      TallyDevices.report_companies(device, [
        %{
          "name" => "Aurora Books",
          "tally_guid" => "aurora",
          "gstin" => "29AAVCS8021P1ZB"
        }
      ])

    {:ok, view, _html} = live(conn, ~p"/clients/new")

    assert has_element?(
             view,
             "#client_tally_company_id option[value='#{company.id}']",
             "Aurora Books · Accounts PC"
           )

    html =
      view
      |> form("#client-form", client: %{tally_company_id: company.id})
      |> render_change()

    assert html =~ ~s(value="Aurora Books")
    assert html =~ ~s(value="29AAVCS8021P1ZB")

    result =
      view
      |> form("#client-form", client: %{tally_company_id: company.id, name: "Aurora Foods"})
      |> render_submit()

    assert [client] = Clients.list_clients(org.id)
    assert client.name == "Aurora Foods"
    assert client.gstin == "29AAVCS8021P1ZB"
    assert [%{id: company_id}] = TallyDevices.list_open_companies(org.id, client.id)
    assert company_id == company.id

    assert {:error, {:live_redirect, %{to: "/clients"}}} = result
  end

  test "a blank name shows an error and creates nothing", %{conn: conn, org: org} do
    {:ok, view, _html} = live(conn, ~p"/clients/new")

    html =
      view
      |> form("#client-form", client: %{name: ""})
      |> render_submit()

    assert html =~ "can&#39;t be blank"
    assert Clients.list_clients(org.id) == []
  end

  test "a bad GSTIN shows an error and creates nothing", %{conn: conn, org: org} do
    {:ok, view, _html} = live(conn, ~p"/clients/new")

    html =
      view
      |> form("#client-form",
        client: %{name: "Aurora Foods", gstin: "NOTAGSTIN"}
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
