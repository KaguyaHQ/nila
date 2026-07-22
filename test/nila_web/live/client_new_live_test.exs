defmodule NilaWeb.ClientNewLiveTest do
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Nila.Clients

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()
    %{conn: log_in_user(conn, user), org: org}
  end

  test "creates a client and lands in prefilled intake", %{conn: conn, org: org} do
    {:ok, view, _html} = live(conn, ~p"/clients/new")

    assert has_element?(view, "#client-form")

    result =
      view
      |> form("#client-form", client: %{name: "Aurora Foods", type: "company"})
      |> render_submit()

    assert [client] = Clients.list_clients(org.id)
    assert client.name == "Aurora Foods"
    assert client.org_id == org.id

    path = "/gst/upload?client_id=#{client.id}"
    assert {:error, {:live_redirect, %{to: ^path}}} = result

    {:ok, intake, html} = follow_redirect(result, conn)
    assert html =~ "Client added — now bring in their documents."
    assert has_element?(intake, "#gst-upload-form option[selected][value='#{client.id}']")

    closeable = Nila.Gst.Filing.Calendar.closeable_period(Date.utc_today())
    assert has_element?(intake, "#gst-upload-form option[selected][value='#{closeable}']")
  end

  test "chase consent fields render and email points to Connectors when Gmail is absent", %{
    conn: conn,
    org: org
  } do
    {:ok, view, _html} = live(conn, ~p"/clients/new")

    assert has_element?(view, "#client_email")
    assert has_element?(view, "#client_chase_channel", "We'll send asks ourselves")
    assert has_element?(view, "#client_chase_channel", "WhatsApp")

    html =
      view
      |> form("#client-form",
        client: %{
          name: "Aurora Foods",
          type: "company",
          email: "accounts@aurora.example",
          chase_channel: "email"
        }
      )
      |> render_submit()

    assert html =~ "requires a connected Gmail account"
    assert html =~ "Settings → Connectors"
    assert Clients.list_clients(org.id) == []
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
