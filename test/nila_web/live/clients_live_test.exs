defmodule NilaWeb.ClientsLiveTest do
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Nila.Clients
  alias Nila.TallyDevices

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()
    %{conn: log_in_user(conn, user), org: org}
  end

  test "lists client identity and setup without workflow state", %{conn: conn, org: org} do
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
    assert has_element?(view, "#clients-table", "Not connected")
    assert has_element?(view, "#client-edit-#{client.id}", "Edit")

    html = render(view)
    refute html =~ "Latest month"
    refute html =~ "Needs a decision"
    refute html =~ "Collecting documents"
    refute html =~ ">Type<"
  end

  test "shows the linked Tally company even when it is not currently open", %{
    conn: conn,
    org: org
  } do
    {:ok, client} =
      Clients.create_client(%{org_id: org.id, name: "Breeze Tech", type: "company"})

    {:ok, device, _token} = TallyDevices.create_device(org, %{name: "Accounts PC"})

    {:ok, [company]} =
      TallyDevices.report_companies(device, [
        %{"name" => "Breeze Books", "tally_guid" => "breeze"}
      ])

    assert {:ok, linked_client} =
             TallyDevices.update_client_and_link_company(client, company.id, %{})

    assert linked_client.id == client.id
    assert :ok = TallyDevices.mark_companies_closed(device.id)

    {:ok, view, _html} = live(conn, ~p"/clients")

    assert has_element?(view, "#clients-table", "Breeze Tech")
    refute has_element?(view, "#client-#{client.id}", "Not connected")
    assert has_element?(view, "#client-#{client.id}", "Breeze Books")
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
