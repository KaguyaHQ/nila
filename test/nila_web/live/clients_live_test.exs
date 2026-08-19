defmodule NilaWeb.ClientsLiveTest do
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Nila.Clients
  alias Nila.TallyDevices

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
    assert has_element?(view, "#clients-table .min-w-0.wrap-break-word", "Breeze Tech")
    assert render(view) =~ "Breeze Tech"
  end

  test "a client with both sides worked shows its status and needs-decision count", %{
    conn: conn,
    org: org
  } do
    client = client_fixture(org, gstin: "27AAPFU0939F1ZV")
    purchase_month(org, client, "2025-10", "worked")
    sales_month(org, client, "2025-10", "worked")

    {:ok, view, _html} = live(conn, ~p"/clients")

    html = render(view)
    assert html =~ "Oct 2025"
    assert html =~ "Ready for review"
    assert has_element?(view, "#client-decisions-#{client.id}", "2")
    assert has_element?(view, "#client-edit-#{client.id}[data-variant='ghost']", "Edit")
    refute has_element?(view, "[data-tip]")
    refute html =~ "no GSTIN"
  end

  test "the decision count lands on that month's working paper", %{conn: conn, org: org} do
    client = client_fixture(org)
    purchase_month(org, client, "2025-10", "worked")
    sales_month(org, client, "2025-10", "worked")

    {:ok, view, _html} = live(conn, ~p"/clients")

    assert view
           |> element("#client-decisions-#{client.id}")
           |> render_click()
           |> follow_redirect(conn, ~p"/gst/#{client.id}/2025-10")
  end

  # The bug this column had: it read the purchase state alone, so a client whose
  # GSTR-1 had never been worked still advertised itself as ready for a senior.
  test "status reports the least advanced side, not the purchase side", %{conn: conn, org: org} do
    client = client_fixture(org)
    purchase_month(org, client, "2025-10", "filed")

    {:ok, view, _html} = live(conn, ~p"/clients")

    html = render(view)
    assert html =~ "Collecting documents"
    refute html =~ "Ready for review"
    refute html =~ "Filed"
  end

  test "a sales-only month still gives the client a latest month", %{conn: conn, org: org} do
    client = client_fixture(org)
    sales_month(org, client, "2025-11", "worked")

    {:ok, view, _html} = live(conn, ~p"/clients")

    html = render(view)
    assert html =~ "Nov 2025"
    refute html =~ "no months yet"
  end

  # Latest month spans both sides, and a side with nothing filed *for that
  # period* has not started it — the older purchase month must not lend its
  # state to a period it isn't in.
  test "the latest month is the later of the two sides", %{conn: conn, org: org} do
    client = client_fixture(org)
    purchase_month(org, client, "2025-10", "reviewed")
    sales_month(org, client, "2025-11", "reviewed")

    {:ok, view, _html} = live(conn, ~p"/clients")

    html = render(view)
    assert html =~ "Nov 2025"
    refute html =~ "Oct 2025"
    assert html =~ "Collecting documents"
    refute has_element?(view, "#client-decisions-#{client.id}")
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

  test "bulk imports selected discovered Tally companies as clients", %{conn: conn, org: org} do
    {:ok, device, _token} = TallyDevices.create_device(org, %{name: "Accounts PC"})

    {:ok, [nila, demo]} =
      TallyDevices.report_companies(device, [
        %{"name" => "Nila", "tally_guid" => "nila"},
        %{"name" => "Demo Company", "tally_guid" => "demo"}
      ])

    {:ok, view, _html} = live(conn, ~p"/clients")

    assert has_element?(view, "#clients-import-tally", "Import clients from Tally")
    assert has_element?(view, "#clients-tally-company-#{nila.id}", "Nila")
    assert has_element?(view, "#clients-tally-company-#{demo.id}", "Demo Company")

    view
    |> form("#clients-import-tally-form", %{"company_ids" => [Integer.to_string(nila.id)]})
    |> render_submit()

    assert render(view) =~ "Tally companies imported — 1 created"
    assert render(view) =~ "Nila"
    refute has_element?(view, "#clients-tally-company-#{nila.id}")
    assert has_element?(view, "#clients-tally-company-#{demo.id}")

    assert [client] = Clients.list_clients(org.id)
    assert client.name == "Nila"
    nila_company_id = nila.id
    assert [%{id: ^nila_company_id}] = TallyDevices.list_open_companies(org.id, client.id)
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

  defp client_fixture(org, attrs \\ []) do
    {:ok, client} =
      Clients.create_client(
        Enum.into(attrs, %{org_id: org.id, name: "Breeze Tech", type: "company"})
      )

    client
  end

  # Five register rows, three matched: two still want a human.
  defp purchase_month(org, client, period, state) do
    {:ok, month} =
      Nila.Gst.Purchase.Months.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: period,
        state: state,
        register_rows: [],
        recon: %{},
        summary: %{"buckets" => %{"matched" => 3, "in_books_not_2b" => 2}}
      })

    month
  end

  defp sales_month(org, client, period, state) do
    {:ok, month} =
      Nila.Gst.Sales.Months.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: period,
        state: state,
        invoices: [],
        derived_gstr1: %{},
        issues: [],
        summary: %{}
      })

    month
  end
end
