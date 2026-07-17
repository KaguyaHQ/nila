defmodule NilaWeb.ClientsLiveTest do
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Nila.Clients

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()
    %{conn: log_in_user(conn, user), org: org}
  end

  test "lists the org's clients", %{conn: conn, org: org} do
    {:ok, _client} =
      Clients.create_client(%{org_id: org.id, name: "Breeze Tech", type: "company"})

    {:ok, view, _html} = live(conn, ~p"/clients")

    assert has_element?(view, "#clients-page")
    assert has_element?(view, "#clients-add")
    assert has_element?(view, "#clients-table")
    assert render(view) =~ "Breeze Tech"
  end

  test "a client with a worked month shows its status and needs-decision count", %{
    conn: conn,
    org: org
  } do
    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Breeze Tech",
        type: "company",
        gstin: "27AAPFU0939F1ZV"
      })

    {:ok, _} =
      Nila.Gst.ClientMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: "2025-10",
        state: "worked",
        register_rows: [],
        recon: %{},
        summary: %{"buckets" => %{"matched" => 3, "in_books_not_2b" => 2}}
      })

    {:ok, view, _html} = live(conn, ~p"/clients")

    html = render(view)
    assert html =~ "Oct 2025"
    assert html =~ "Ready for review"
    assert has_element?(view, "#client-edit-#{client.id}")
    refute html =~ "no GSTIN"
  end

  test "a client without a GSTIN gets a warning badge", %{conn: conn, org: org} do
    {:ok, _client} =
      Clients.create_client(%{org_id: org.id, name: "Breeze Tech", type: "company"})

    {:ok, view, _html} = live(conn, ~p"/clients")

    assert render(view) =~ "no GSTIN"
  end

  test "shows an empty state when the org has no clients", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/clients")

    assert has_element?(view, "#clients-page")
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
