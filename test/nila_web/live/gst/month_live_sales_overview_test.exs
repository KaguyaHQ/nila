defmodule NilaWeb.Gst.MonthLiveSalesOverviewTest do
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Nila.GstFixtures

  alias Nila.Clients

  @period "2025-10"

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Breeze Tech",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    work_dump!(org, client, @period, "sales", "%PDF-1.4 fake bytes", user.id)

    %{conn: log_in_user(conn, user), org: org, client: client, user: user}
  end

  test "go to supplies local search data without a server search form", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _} = live(conn, "/gst/#{client.id}/#{@period}/sales")
    view |> element("#shell-client-switcher") |> render_hook("open", %{"palette" => "true"})
    assert has_element?(view, "#shell-client-switcher-sheet-title", "Go to")
    assert has_element?(view, "#shell-client-switcher-navigation[phx-hook=CommandPalette]")
    refute has_element?(view, "#shell-client-switcher-search-form[phx-change]")
    refute has_element?(view, "#client_switcher_query[phx-debounce]")

    assert has_element?(
             view,
             "#go-to-destinations [data-command-search='Sales register sales bills invoices']"
           )

    assert has_element?(
             view,
             "#shell-client-switcher-client-#{client.id}[data-command-search='#{client.name} #{client.gstin}']"
           )
  end

  test "opens the global client switcher from a client month", %{
    conn: conn,
    org: org,
    client: client,
    user: user
  } do
    {:ok, caltech} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Caltech",
        type: "company"
      })

    work_dump!(org, caltech, @period, "sales", "%PDF-1.4 caltech bytes", user.id)

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}/sales")

    assert has_element?(
             view,
             "#shell-client-switcher-trigger[aria-expanded='false']",
             "Breeze Tech"
           )

    view |> element("#shell-client-switcher-trigger") |> render_click()

    assert has_element?(view, "#shell-client-switcher-trigger[aria-expanded='true']")

    assert has_element?(
             view,
             "#shell-client-switcher-sheet[role='dialog']",
             "Switch client"
           )

    assert has_element?(
             view,
             "#shell-client-switcher-navigation[phx-hook='SelectableList'][data-loop='true']"
           )

    assert has_element?(
             view,
             "#client_switcher_query[role='combobox'][aria-controls='shell-client-switcher-options']"
           )

    assert has_element?(
             view,
             "#shell-client-switcher-options[role='listbox'][aria-label='Clients']"
           )

    assert has_element?(
             view,
             "button#shell-client-switcher-client-#{client.id}[data-state='selected'][aria-selected='true']",
             "Current"
           )

    assert has_element?(
             view,
             "#shell-client-switcher-client-#{caltech.id}[href*='/clients/#{caltech.id}/select']",
             "Caltech"
           )

    view
    |> form("#shell-client-switcher-search-form", %{
      "client_switcher" => %{"query" => "calt"}
    })
    |> render_change()

    assert has_element?(view, "#shell-client-switcher-client-#{caltech.id}", "Caltech")
    refute has_element?(view, "#shell-client-switcher-client-#{client.id}")

    view
    |> element("#shell-client-switcher-sheet button[phx-click='close']")
    |> render_click()

    refute has_element?(view, "#shell-client-switcher-sheet")
  end

  test "switching clients keeps the register filter but clears the previous buyer search", %{
    conn: conn,
    org: org,
    client: client
  } do
    {:ok, other} = Clients.create_client(%{org_id: org.id, name: "Next Client", type: "company"})

    {:ok, view, _} =
      live(conn, "/gst/#{client.id}/#{@period}/sales/invoices?q=OldBuyer&filter=review_cases")

    view |> element("#shell-client-switcher-trigger") |> render_click()

    destination = "/gst/#{other.id}/#{@period}/sales/invoices?filter=review_cases"
    switch_path = "/clients/#{other.id}/select?" <> URI.encode_query(%{return_to: destination})

    assert has_element?(
             view,
             "#shell-client-switcher-client-#{other.id}[data-to='#{switch_path}']"
           )
  end
end
