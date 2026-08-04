defmodule NilaWeb.Gst.SalesReviewLiveTest do
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Nila.GstFixtures

  alias Nila.Accounts.Scope
  alias Nila.Clients
  alias Nila.Gst.Filing.Signoffs
  alias Nila.Gst.Sales.{Gstr1, Resolutions}
  alias Nila.Gst.Sales.Months, as: SalesMonths

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
    {:ok, month} = SalesMonths.get_by_period(org.id, client.id, @period)
    workings = Resolutions.workings(month)

    %{
      conn: log_in_user(conn, user),
      org: org,
      client: client,
      user: user,
      month: month,
      workings: workings
    }
  end

  test "canonical sales routes preserve MonthLive and legacy invoice links replace", context do
    [open | _] = context.workings.active_invoices
    path = review_path(context.client, open["id"], "needs_you")
    {:ok, view, _html} = live(context.conn, path)
    month_pid = view.pid

    assert has_element?(view, "#month-page")
    assert has_element?(view, "#sales-review")
    assert has_element?(view, "#gstr1-evidence-modal")

    view |> element("#sales-review-scope button", "All") |> render_click()
    assert_patch(view, review_path(context.client, open["id"], "all"))
    assert view.pid == month_pid

    assert {:error, {:live_redirect, %{to: legacy_target}}} =
             live(context.conn, ~p"/gst/#{context.client.id}/#{@period}?invoice=20%2F2025-26")

    assert legacy_target == review_path(context.client, open["id"], "needs_you")
  end

  test "missing and unknown route state canonicalizes to needs-you first, then all", context do
    [open | _] = context.workings.active_invoices
    clean = Enum.at(context.workings.active_invoices, 1)

    assert {:error, {:live_redirect, %{to: missing_target}}} =
             live(context.conn, "/gst/#{context.client.id}/#{@period}/review/sales")

    assert missing_target == review_path(context.client, open["id"], "needs_you")

    assert {:error, {:live_redirect, %{to: unknown_target}}} =
             live(
               context.conn,
               "/gst/#{context.client.id}/#{@period}/review/sales?item=unknown&scope=wat"
             )

    assert unknown_target == review_path(context.client, open["id"], "needs_you")

    assert {:error, {:live_redirect, %{to: clean_target}}} =
             live(
               context.conn,
               "/gst/#{context.client.id}/#{@period}/review/sales?item=#{clean["id"]}"
             )

    assert clean_target == review_path(context.client, clean["id"], "all")
  end

  test "rail scopes keep register order, stable progress, and non-wrapping navigation", context do
    [first, second, third] = context.workings.active_invoices
    {:ok, view, _html} = live(context.conn, review_path(context.client, first["id"], "all"))

    assert has_element?(view, "#sales-review-progress", "0 of 1 checks complete")
    assert has_element?(view, "#sales-review-month-checks", "month checks remain")

    rail = view |> element("#sales-review-rail") |> render()
    assert position(rail, first["id"]) < position(rail, second["id"])
    assert position(rail, second["id"]) < position(rail, third["id"])
    assert has_element?(view, "#gstr1-review-previous[disabled]", "Previous")
    assert has_element?(view, "#gstr1-review-next:not([disabled])", "Next")

    view |> element("#gstr1-review-next") |> render_click()
    assert_patch(view, review_path(context.client, second["id"], "all"))
    assert has_element?(view, "#gstr1-review-previous:not([disabled])")

    view |> element("#sales-review-scope button", "Needs you") |> render_click()
    assert has_element?(view, "#sales-review-progress", "0 of 1 checks complete")
    assert has_element?(view, "#gstr1-review-previous[disabled]")
    assert has_element?(view, "#gstr1-review-next[disabled]")
  end

  test "invoice detail uses the shared frame and overlay, with no second action surface",
       context do
    [open | _] = context.workings.active_invoices
    {:ok, view, _html} = live(context.conn, review_path(context.client, open["id"], "needs_you"))

    assert has_element?(view, "#gstr1-evidence-frame")
    assert has_element?(view, "#gstr1-evidence-frame-open")
    refute has_element?(view, "#gstr1-evidence-images > img")

    assert Enum.count(
             LazyHTML.query(LazyHTML.from_fragment(render(view)), "#gstr1-evidence-modal")
           ) == 1

    view |> element("#gstr1-evidence-frame-open") |> render_click()
    assert has_element?(view, "#gstr1-evidence-overlay")
    view |> element("#gstr1-evidence-overlay-close") |> render_click()
    refute has_element?(view, "#gstr1-evidence-overlay")
  end

  test "decision, undo, and correction writes are owned by SalesLive", context do
    [open, correction | _] = context.workings.active_invoices
    {:ok, view, _html} = live(context.conn, review_path(context.client, open["id"], "all"))

    view
    |> element("#sales-review-component button[phx-click='resolve-invoice-issue']")
    |> render_click()

    assert Enum.any?(Resolutions.list(context.month.id), fn resolution ->
             resolution.verb == "confirm_issue" and
               resolution.target == "#{open["id"]}:grand_total_mismatch"
           end)

    {:ok, resolved_view, _html} =
      live(context.conn, review_path(context.client, open["id"], "all"))

    assert has_element?(resolved_view, "#sales-review-component button[phx-click='undo']")

    resolved_view
    |> element("#sales-review-component button[phx-click='undo']")
    |> render_click()

    refute Enum.any?(Resolutions.workings(context.month).issues, fn issue ->
             issue["source_id"] == open["id"] and issue["status"] == "resolved"
           end)

    make_gstin_correctable!(context.month, correction["id"], context.client)

    {:ok, correction_view, _html} =
      live(context.conn, review_path(context.client, correction["id"], "needs_you"))

    correction_view
    |> element("#gstr1-corrections button[phx-click='start_correct']")
    |> render_click()

    correction_view
    |> form("#gstr1-correction-form", %{
      "correction" => %{"field" => "buyer_gstin", "value" => "33AABCP9487A1ZG"}
    })
    |> render_submit()

    assert Enum.any?(Resolutions.list(context.month.id), fn resolution ->
             resolution.verb == "correct_field" and resolution.target == correction["id"]
           end)
  end

  test "a clean treatment is untouched until challenged, then becomes confirmable", context do
    clean = Enum.at(context.workings.active_invoices, 1)
    {:ok, view, _html} = live(context.conn, review_path(context.client, clean["id"], "all"))

    assert has_element?(view, "#sales-review-challenge", "Challenge this treatment")
    assert Resolutions.list(context.month.id) == []

    view |> element("#sales-review-challenge") |> render_click()
    assert_patch(view, review_path(context.client, clean["id"], "needs_you"))

    assert Enum.any?(Resolutions.list(context.month.id), &(&1.verb == "challenge_treatment"))
    assert has_element?(view, "#gstr1-evidence-modal", "Reviewer challenged Nila")
    assert has_element?(view, "button[phx-click='resolve-invoice-issue']")
  end

  test "signed and filed clean treatments explain why challenge is disabled", context do
    sign_month!(context)
    clean = Enum.at(context.workings.active_invoices, 1)
    path = review_path(context.client, clean["id"], "all")
    {:ok, signed, _html} = live(context.conn, path)

    assert has_element?(
             signed,
             "#sales-review-challenge[disabled]",
             "Reopen GSTR-1 approval first"
           )

    {:ok, month} = SalesMonths.get_by_period(context.org.id, context.client.id, @period)
    {:ok, _month} = Signoffs.mark_filed(month, Scope.for_user(context.user))
    {:ok, filed, _html} = live(context.conn, path)

    assert has_element?(
             filed,
             "#sales-review-challenge[disabled]",
             "Filed returns require an amendment."
           )
  end

  test "month issue actions remain outside the invoice surface", context do
    {:ok, month_view, _html} = live(context.conn, ~p"/gst/#{context.client.id}/#{@period}")

    assert has_element?(month_view, "#gstr1-review-required[data-phx-link='patch']")
    refute has_element?(month_view, "#gstr1-evidence-modal")
    refute has_element?(month_view, "#month-page button[phx-click='resolve-invoice-issue']")
    assert has_element?(month_view, "#gstr1-checks-before-filing")
  end

  defp sign_month!(context) do
    confirm_sales_complete!(context.org, context.client, @period)
    answer_sales_issues!(context.month, context.user.id)
    {:ok, month} = SalesMonths.get_by_period(context.org.id, context.client.id, @period)
    {:ok, _signoff} = Signoffs.sign_off_gstr1(month, Scope.for_user(context.user))
  end

  defp make_gstin_correctable!(month, source_id, client) do
    invoices =
      Enum.map(month.invoices, fn
        %{"id" => ^source_id} = invoice -> Map.put(invoice, "buyer_gstin", "BADGSTIN")
        invoice -> invoice
      end)

    {:ok, _month} =
      SalesMonths.upsert(%{
        org_id: month.org_id,
        client_id: month.client_id,
        period: month.period,
        invoices: invoices,
        issues: Gstr1.validation_issues(invoices),
        derived_gstr1: Gstr1.derive(invoices, Gstr1.production_header(client.gstin, month.period))
      })
  end

  defp review_path(client, item, scope) do
    "/gst/#{client.id}/#{@period}/review/sales?item=#{item}&scope=#{scope}"
  end

  defp position(haystack, needle), do: elem(:binary.match(haystack, needle), 0)
end
