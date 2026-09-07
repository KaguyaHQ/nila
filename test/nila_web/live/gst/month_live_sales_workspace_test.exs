defmodule NilaWeb.Gst.MonthLiveSalesWorkspaceTest do
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

    %{conn: log_in_user(conn, user), client: client}
  end

  test "renders the filing period as a compact source, return, and handoff index", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}/sales")

    assert has_element?(view, "#sales-period-workspace", "Breeze Tech / Sales & GSTR-1")
    assert has_element?(view, "#sales-period-workspace", "Sales invoices")
    assert has_element?(view, "#sales-period-return-heading", "GSTR-1 tables")
    assert has_element?(view, "#sales-period-workspace", "Export")
    assert has_element?(view, "#sales-period-status", "Review the GST working before exporting.")
    refute has_element?(view, "#sales-period-workflow")
    assert has_element?(view, "#sales-period-primary-action", "Review")

    refute has_element?(view, "#sales-period-primary-action", "Bring in invoices")
    refute has_element?(view, "#sales-period-primary-action", "Approve GSTR-1")
    refute has_element?(view, "#sales-period-workspace", "Sales population")
    refute has_element?(view, "#sales-period-workspace", "Handoff")
    assert has_element?(view, "th", "Taxable value")
    assert has_element?(view, "#sales-period-uploads-link", "Uploads")
    assert has_element?(view, "#sales-period-uploads-link", "1 file")
    refute has_element?(view, "#sales-period-workspace header", "overdue")
    assert has_element?(view, "#sales-period-return-b2b", "B2B")
    assert has_element?(view, "#sales-period-return-b2b", "Draft")
    assert has_element?(view, "th", "Entries")
    assert has_element?(view, "#sales-period-return-hsn", "HSN-wise summary")
    assert has_element?(view, "#sales-period-return-documents", "Documents issued")
    assert has_element?(view, "#sales-period-handoff-winman", "Winman GSTR-1")
    assert has_element?(view, "#sales-period-handoff-json", "GSTR-1 · JSON")
    assert has_element?(view, "#sales-period-handoff-workings", "GST sales working")

    assert has_element?(view, "#sales-period-handoff-workings", "XLSX")
    assert has_element?(view, "#sales-period-handoff-winman", "XLSM")
    assert has_element?(view, "#sales-period-handoff-json", "JSON")
    assert has_element?(view, "#sales-period-export", "before exporting.")
    refute has_element?(view, "#sales-period-export a[download]")
    assert has_element?(view, "#sales-period-overview", "invoices in working")
    refute render(view) =~ "Blocked by"
    refute render(view) =~ "Needs approval"
    refute render(view) =~ "unresolved"
    assert has_element?(view, "aside a[aria-current='page']", "Sales & GSTR-1")
    refute has_element?(view, "#month-workpapers")
    refute has_element?(view, "#gstr1-human-assurance-count")
  end

  test "the sidebar opens the selected client's current sales period even when it is empty", %{
    conn: conn,
    client: client
  } do
    current_period = Nila.Gst.Filing.Calendar.closeable_period(Date.utc_today())
    path = ~p"/gst/#{client.id}/#{current_period}/sales"
    {:ok, view, _html} = live(conn, path)

    assert has_element?(view, "#sales-period-workspace")
    assert has_element?(view, "aside a[href='#{path}']", "Sales & GSTR-1")

    assert has_element?(
             view,
             "#sales-period-status",
             "Add invoices to prepare this month's GST working."
           )

    assert has_element?(view, "#sales-period-primary-action", "Bring in invoices")
    refute has_element?(view, "#sales-period-primary-download")
    refute has_element?(view, "#sales-period-handoff-download-workings")

    assert has_element?(
             view,
             "#sales-period-primary-action a[href='/gst/upload?client_id=#{client.id}&period=#{current_period}&kind=sales']"
           )

    refute has_element?(view, "#sales-period-primary-action", "Approve GSTR-1")
    assert has_element?(view, "#sales-period-uploads-link", "0 batches · 0 files")

    assert has_element?(view, "#sales-period-export", "Add invoices to make exports available.")
    refute has_element?(view, "#sales-period-export a[download]")

    assert has_element?(view, "a", "Bring in invoices")

    {:ok, register, _html} = live(conn, path <> "/invoices")

    assert has_element?(
             register,
             "#sales-period-workspace .nila-table-shell",
             "No invoices match this view."
           )
  end

  test "month navigation reaches the current month and stops there", %{conn: conn, client: client} do
    current = Calendar.strftime(Date.utc_today(), "%Y-%m")
    previous = Nila.Gst.Filing.Calendar.closeable_period(Date.utc_today())
    {:ok, view, _} = live(conn, ~p"/gst/#{client.id}/#{previous}/sales")

    assert has_element?(view, "a#next-filing-period[href='/gst/#{client.id}/#{current}/sales']")

    {:ok, current_view, _} = live(conn, ~p"/gst/#{client.id}/#{current}/sales")
    assert has_element?(current_view, "button#next-filing-period[disabled]")
    refute has_element?(current_view, "#next-filing-period[href]")

    assert has_element?(
             current_view,
             "a#previous-filing-period[href='/gst/#{client.id}/#{previous}/sales']"
           )

    assert has_element?(
             current_view,
             "aside a[href='/gst/#{client.id}/#{previous}/sales']",
             "Sales & GSTR-1"
           )
  end

  test "the bare legacy month route sends sales work to the period workspace", %{
    conn: conn,
    client: client
  } do
    assert {:error, {:live_redirect, %{to: path}}} =
             live(conn, ~p"/gst/#{client.id}/#{@period}")

    assert path == ~p"/gst/#{client.id}/#{@period}/sales"
  end

  test "an existing empty working offers no export downloads", %{conn: conn, client: client} do
    alias Nila.Gst.Sales.{Gstr1, Months}

    {:ok, _} =
      Months.upsert(%{
        org_id: client.org_id,
        client_id: client.id,
        period: "2026-07",
        state: "worked",
        invoices: [],
        issues: [],
        derived_gstr1: Gstr1.derive([], Gstr1.production_header(client.gstin, "2026-07"))
      })

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/2026-07/sales")

    for kind <- ["workings", "winman", "json"] do
      refute has_element?(view, "#sales-period-handoff-download-#{kind}")
      refute has_element?(view, "#sales-period-handoff-#{kind}", "Unavailable — add invoices")
    end

    assert has_element?(
             view,
             "#sales-period-export > p",
             "Add invoices to make exports available."
           )

    refute has_element?(view, "#sales-period-primary-download")
  end

  test "keeps empty statutory rows visible but inert", %{conn: conn, client: client} do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}/sales")

    assert has_element?(view, "#sales-period-return-b2cl", "No entries")
    refute has_element?(view, "#sales-period-return-b2cl a")
    refute has_element?(view, "#sales-period-return-b2cl", "hero-chevron-right")
  end

  test "drills from the period into the consolidated invoice register", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}/sales")

    assert has_element?(
             view,
             "#sales-period-overview a[href='/gst/#{client.id}/#{@period}/sales/invoices']"
           )

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}/sales/invoices")
    assert has_element?(view, "#sales-period-invoices")
    assert has_element?(view, "#sales-period-register-filters", "Needs review")
    refute has_element?(view, "#sales-period-return")
  end

  test "renders each active drill-down as its own route", %{conn: conn, client: client} do
    for {path, selector} <- [
          {~p"/gst/#{client.id}/#{@period}/sales/uploads", "#sales-period-source-record"},
          {~p"/gst/#{client.id}/#{@period}/sales/b2b", "#sales-period-gstr1-table-b2b"},
          {~p"/gst/#{client.id}/#{@period}/sales/hsn", "#gstr1-table-12-rows"},
          {~p"/gst/#{client.id}/#{@period}/sales/documents", "#sales-period-documents"}
        ] do
      {:ok, view, _html} = live(conn, path)
      assert has_element?(view, selector)
      assert has_element?(view, "a", "Period overview")
    end
  end
end
