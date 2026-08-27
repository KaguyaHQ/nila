defmodule NilaWeb.ClientEditLiveTest do
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Nila.Clients
  alias Nila.TallyDevices

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        "org_id" => org.id,
        "name" => "Aurora Foods",
        "type" => "company"
      })

    %{conn: log_in_user(conn, user), org: org, client: client}
  end

  test "edits a client and redirects to the list showing the new value", %{
    conn: conn,
    org: org,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/clients/#{client.id}/edit")

    assert has_element?(view, "#client-form")
    assert has_element?(view, "#client_name")
    assert has_element?(view, "#client_gstin")
    assert has_element?(view, "#client_pan")
    refute has_element?(view, "#client_type")
    refute has_element?(view, "#client_email")
    refute has_element?(view, "#client_phone")
    refute has_element?(view, "#client_chase_channel")

    result =
      view
      |> form("#client-form", client: %{name: "Borealis Foods"})
      |> render_submit()

    assert {:error, {:live_redirect, %{to: "/clients"}}} = result

    assert {:ok, updated} = Clients.get_client(org.id, client.id)
    assert updated.name == "Borealis Foods"

    {:ok, list_view, _html} = live(conn, ~p"/clients")
    assert render(list_view) =~ "Borealis Foods"
  end

  test "a blank name shows an error and does not persist", %{conn: conn, org: org, client: client} do
    {:ok, view, _html} = live(conn, ~p"/clients/#{client.id}/edit")

    html =
      view
      |> form("#client-form", client: %{name: ""})
      |> render_submit()

    assert html =~ "can&#39;t be blank"
    assert {:ok, unchanged} = Clients.get_client(org.id, client.id)
    assert unchanged.name == "Aurora Foods"
  end

  test "connects a manually created client to a previously discovered Tally company", %{
    conn: conn,
    org: org,
    client: client
  } do
    {:ok, device, _token} = TallyDevices.create_device(org, %{name: "Accounts PC"})

    {:ok, [company]} =
      TallyDevices.report_companies(device, [
        %{"name" => "Aurora Books", "tally_guid" => "aurora"}
      ])

    assert :ok = TallyDevices.mark_companies_closed(device.id)
    {:ok, view, _html} = live(conn, ~p"/clients/#{client.id}/edit")

    assert has_element?(
             view,
             "#client_tally_company_id option[value='#{company.id}']",
             "Aurora Books · Accounts PC"
           )

    result =
      view
      |> form("#client-form",
        client: %{name: client.name, tally_company_id: company.id}
      )
      |> render_submit()

    assert {:error, {:live_redirect, %{to: "/clients"}}} = result
    assert [%{id: company_id}] = TallyDevices.list_linked_companies(org.id)
    assert company_id == company.id
  end

  test "changing the Tally company replaces the current destination", %{
    conn: conn,
    org: org,
    client: client
  } do
    {:ok, device, _token} = TallyDevices.create_device(org, %{name: "Accounts PC"})

    {:ok, [old_company, new_company]} =
      TallyDevices.report_companies(device, [
        %{"name" => "Aurora Old", "tally_guid" => "aurora-old"},
        %{"name" => "Aurora Current", "tally_guid" => "aurora-current"}
      ])

    assert {:ok, _client} =
             TallyDevices.update_client_and_link_company(client, old_company.id, %{})

    {:ok, view, _html} = live(conn, ~p"/clients/#{client.id}/edit")

    assert has_element?(view, "#client-edit-page", "Aurora Old · Accounts PC")
    assert has_element?(view, "#client_tally_company_id", "Keep current company")

    result =
      view
      |> form("#client-form",
        client: %{name: client.name, tally_company_id: new_company.id}
      )
      |> render_submit()

    assert {:error, {:live_redirect, %{to: "/clients"}}} = result
    assert Nila.Repo.reload!(client).active_tally_company_id == new_company.id
  end

  test "a bad GSTIN shows an error and does not persist", %{conn: conn, org: org, client: client} do
    {:ok, view, _html} = live(conn, ~p"/clients/#{client.id}/edit")

    html =
      view
      |> form("#client-form", client: %{gstin: "NOTAGSTIN"})
      |> render_submit()

    assert html =~ "is not a valid GSTIN"
    assert {:ok, unchanged} = Clients.get_client(org.id, client.id)
    assert is_nil(unchanged.gstin)
  end

  test "editing another org's client redirects and does not render it", %{conn: conn} do
    %{org: other_org} = user_with_org_fixture(%{org: %{gstin: "27ABCDE1234F1Z0"}})

    {:ok, other_client} =
      Clients.create_client(%{
        "org_id" => other_org.id,
        "name" => "Foreign Client",
        "type" => "company"
      })

    assert {:error, {:live_redirect, %{to: "/clients", flash: %{"error" => _}}}} =
             live(conn, ~p"/clients/#{other_client.id}/edit")
  end

  test "the clients list links each row to its edit page", %{conn: conn, client: client} do
    {:ok, view, _html} = live(conn, ~p"/clients")

    assert has_element?(view, "#client-#{client.id}")
  end

  test "redirects logged-out visitors to log in", %{client: client} do
    assert {:error, {:redirect, %{to: "/users/log_in"}}} =
             live(Phoenix.ConnTest.build_conn(), ~p"/clients/#{client.id}/edit")
  end
end
