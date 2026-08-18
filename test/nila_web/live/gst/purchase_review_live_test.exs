defmodule NilaWeb.Gst.PurchaseReviewLiveTest do
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Nila.GstFixtures

  alias Nila.Clients
  alias Nila.Gst.Filing.Signoffs
  alias Nila.Gst.Purchase.{Groups, Register, Resolutions}
  alias Nila.Gst.Purchase.Months
  alias Nila.Gst.Purchase.Reconciliation

  @gstin "33AAACS1234A1Z9"
  @period "2026-08"

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{org_id: org.id, name: "Breeze", type: "company", gstin: @gstin})

    %{conn: log_in_user(conn, user), user: user, org: org, client: client}
  end

  test "an unpublished GSTR-2B does not become a zero-valued reconciliation", context do
    today = Date.utc_today()
    period = "#{today.year}-#{today.month |> to_string() |> String.pad_leading(2, "0")}"
    put_books_without_2b!(context, period, "awaiting-2b-1")

    {:ok, view, _html} =
      live(context.conn, "/gst/#{context.client.id}/#{period}?track=purchases")

    assert has_element?(view, "#month-workpaper-tab-purchases", "Waiting for GSTR-2B")
    assert has_element?(view, "#purchase-itc-amount-unavailable", "Awaiting GSTR-2B")
    refute has_element?(view, "#purchase-itc-amount")
    refute has_element?(view, "#purchase-itc-proposal-basis")
    assert has_element?(view, "#purchase-itc-basis", "has not published GSTR-2B")
    assert has_element?(view, "#purchase-primary-blocker", "Waiting for 2B")
    assert has_element?(view, "#purchase-next-action", "Wait for the portal")
    refute has_element?(view, "#gstr3b-review-required")
    refute has_element?(view, "#purchase-open-gstr3b")
    refute has_element?(view, "#purchase-required-actions")
    refute has_element?(view, "#purchase-reconciliation-filters")
    refute has_element?(view, "#purchase-action-filters")
    refute has_element?(view, "#purchase-transition-gstr3b")
    assert has_element?(view, "#purchase-transition", "waits until the portal publishes")
    assert has_element?(view, "#gst-register", "Waiting for GSTR-2B")
  end

  test "a published but unimported GSTR-2B exposes only the import action", context do
    period = Nila.Gst.Filing.Calendar.closeable_period(Date.utc_today())
    put_books_without_2b!(context, period, "need-2b-1")

    {:ok, view, _html} =
      live(context.conn, "/gst/#{context.client.id}/#{period}?track=purchases")

    assert has_element?(view, "#month-workpaper-tab-purchases", "GSTR-2B not in")
    assert has_element?(view, "#purchase-itc-amount-unavailable", "GSTR-2B not imported")
    refute has_element?(view, "#purchase-itc-amount")
    refute has_element?(view, "#purchase-itc-proposal-basis")
    assert has_element?(view, "#purchase-itc-basis", "available but not in Nila")
    assert has_element?(view, "#purchase-primary-blocker", "2B not in")
    assert has_element?(view, "#purchase-next-action", "Bring in GSTR-2B")
    assert has_element?(view, "#purchase-bring-gstr2b")
    refute has_element?(view, "#gstr3b-review-required")
    refute has_element?(view, "#purchase-open-gstr3b")
    refute has_element?(view, "#purchase-required-actions")
    refute has_element?(view, "#purchase-reconciliation-filters")
    refute has_element?(view, "#purchase-action-filters")
    refute has_element?(view, "#purchase-transition-gstr3b")
  end

  test "purchase workpaper leads with the ITC conclusion, blocker and next action", context do
    put_month!(
      context,
      [books("hierarchy-1", %{"invoice_number" => "1134"})],
      [gstr2b("CHN-SER-1134")]
    )

    {:ok, view, _html} =
      live(context.conn, "/gst/#{context.client.id}/#{@period}?track=purchases")

    assert has_element?(view, "#purchase-itc-conclusion", "Current proposed ITC")
    assert has_element?(view, "#purchase-itc-proposal-basis-reported", "Reported in GSTR-2B")
    assert has_element?(view, "#purchase-itc-proposal-basis-pending", "pending decisions")
    assert has_element?(view, "#purchase-itc-proposal-basis-claimable", "Current proposed ITC")
    assert has_element?(view, "#purchase-itc-basis", "reported in GSTR-2B")
    assert has_element?(view, "#purchase-itc-basis", "not an eligibility assurance")
    assert has_element?(view, "#purchase-primary-blocker", "Decision required")
    assert has_element?(view, "#purchase-next-action", "Review invoice")
    assert has_element?(view, "#gstr3b-review-required")

    assert_dom_order(view, [
      "purchase-itc-conclusion",
      "purchase-required-actions",
      "purchase-controls",
      "gstr3b-register",
      "purchase-reconciliation-filters"
    ])
  end

  test "document waiting remains inside the proposal and asks for possession", context do
    put_month!(context, [], [gstr2b("WAIT-2B-1")])

    {:ok, view, _html} =
      live(context.conn, "/gst/#{context.client.id}/#{@period}?track=purchases")

    assert has_element?(view, "#purchase-itc-conclusion", "Current proposed ITC")
    assert has_element?(view, "#purchase-primary-blocker", "Evidence pending")
    assert has_element?(view, "#purchase-primary-blocker", "remains inside the proposal")
    assert has_element?(view, "#purchase-next-action", "Collect invoice WAIT-2B-1")
    assert has_element?(view, "#gstr3b-review-required")

    assert_dom_order(view, [
      "purchase-itc-conclusion",
      "purchase-required-actions",
      "purchase-controls",
      "gstr3b-register",
      "purchase-reconciliation-filters"
    ])
  end

  test "clear and frozen positions remain distinct without inventing assurance", context do
    month = put_month!(context, [books("frozen-1")], [gstr2b("INV-001")])

    {:ok, clear, _html} =
      live(context.conn, "/gst/#{context.client.id}/#{@period}?track=purchases")

    assert has_element?(clear, "#purchase-itc-conclusion", "Current proposed ITC")
    assert has_element?(clear, "#purchase-primary-blocker", "No open blocker")
    assert has_element?(clear, "#purchase-next-action", "Open GSTR-3B")
    assert has_element?(clear, "#purchase-open-gstr3b")

    {:ok, _signoff} = Signoffs.sign_off(month, Nila.Accounts.Scope.for_user(context.user))

    {:ok, frozen, _html} =
      live(context.conn, "/gst/#{context.client.id}/#{@period}?track=purchases")

    assert has_element?(frozen, "#purchase-itc-conclusion", "Frozen ITC position")
    assert has_element?(frozen, "#purchase-itc-basis", "Frozen from")
    assert has_element?(frozen, "#purchase-primary-blocker", "Position frozen")
    assert has_element?(frozen, "#purchase-next-action", "frozen return")
    assert has_element?(frozen, "#purchase-open-gstr3b")
    refute has_element?(frozen, "#gstr3b-review-required")
  end

  test "deep links validate scope and select a member through the same MonthLive", context do
    first = books("freezelinks-1")
    second = books("freezelinks-2")
    counterpart = gstr2b("FREEZELINKS")
    month = put_month!(context, [first, second], [counterpart])

    {:ok, view, _html} =
      live(
        context.conn,
        ~p"/gst/#{context.client.id}/#{@period}/review/purchase?item=#{second["id"]}&scope=needs_you"
      )

    assert has_element?(view, "#month-page")
    assert has_element?(view, "#month-workpaper-tab-purchases[aria-current='page']")
    assert has_element?(view, "#month-register")
    refute has_element?(view, "#month-sales")
    assert has_element?(view, "#purchase-review")
    assert has_element?(view, "#gst-exception-books-members")
    members = view |> element("#gst-exception-books-members") |> render()

    assert elem(:binary.match(members, "gst-exception-books-member-freezelinks-2"), 0) <
             elem(:binary.match(members, "gst-exception-books-member-freezelinks-1"), 0)

    assert has_element?(view, "#purchase-review-progress", "0 of 2 decisions")

    view |> element("#purchase-review-scope button", "All") |> render_click()
    assert has_element?(view, "#purchase-review-progress", "0 of 2 decisions")
    assert length(Resolutions.list(month.id)) == 0

    view |> element("#purchase-review button[phx-click='done']") |> render_click()
    assert_patch(view, "/gst/#{context.client.id}/#{@period}?track=purchases")
  end

  test "confirm_pair records the evidence and alternatives shown", context do
    month =
      put_month!(context, [books("b1", %{"invoice_number" => "1134"})], [gstr2b("CHN-SER-1134")])

    {:ok, view, _html} = live(context.conn, review_path(context.client))

    assert has_element?(view, "#gst-exception-queue span.truncate[title='Sharma Steels']")
    assert has_element?(view, "#gst-exception-queue span.truncate[title*='1134']")

    assert has_element?(
             view,
             "#gst-exception-queue [id^='queue-tax-'].whitespace-nowrap.tabular-nums"
           )

    assert has_element?(view, "#gst-exception-detail .wrap-break-word", "1134")
    assert has_element?(view, "#gst-exception-tax.whitespace-nowrap.tabular-nums")

    view |> element("button", "Confirm — same bill") |> render_click()

    assert [resolution] = Resolutions.list(month.id)
    assert resolution.verb == "confirm_pair"
    assert resolution.payload["books"]["id"] == "b1"
    assert resolution.payload["counterpart"]["invoice_number"] == "CHN-SER-1134"
    assert [%{"books_id" => "b1"}] = resolution.payload["alternatives"]
    assert is_binary(resolution.payload["reason"])
  end

  test "a clean automatic match can be challenged into one open question", context do
    month = put_month!(context, [books("b1")], [gstr2b("INV-001")])
    {:ok, view, _html} = live(context.conn, review_path(context.client, "b1", "all"))

    assert has_element?(view, "#gst-challenge-match", "Challenge this match")
    view |> element("#gst-challenge-match") |> render_click()

    assert [resolution] = Resolutions.list(month.id)
    assert resolution.verb == "challenge_pair"

    assert [%{"reason" => %{"code" => "challenged_automatic_match"}}] =
             Resolutions.workings(month).recon["needs_human"]
  end

  test "challenge is disabled after sign-off with a reason", context do
    month = put_month!(context, [books("b1")], [gstr2b("INV-001")])
    {:ok, _} = Signoffs.sign_off(month, Nila.Accounts.Scope.for_user(context.user))

    {:ok, view, _html} = live(context.conn, review_path(context.client, "b1", "all"))

    assert has_element?(view, "#gst-challenge-match[disabled]")
    assert has_element?(view, "#gst-challenge-match[title*='Unlock']")
  end

  test "correction records from the component and re-runs reconciliation", context do
    month =
      put_month!(context, [books("b1", %{"invoice_number" => "1134"})], [gstr2b("CHN-SER-1134")])

    {:ok, view, _html} = live(context.conn, review_path(context.client))

    view |> element("button", "Correct the number") |> render_click()

    view
    |> form("#gst-exception-detail form", %{"id" => "b1", "value" => "CHN-SER-1134"})
    |> render_submit()

    assert [resolution] = Resolutions.list(month.id)
    assert resolution.verb == "correct_field"
    assert resolution.books_id == "b1"
    assert get_in(resolution.payload, ["to"]) == "CHN-SER-1134"
    assert [%{"books" => %{"id" => "b1"}}] = Resolutions.workings(month).recon["matched"]
  end

  test "missing-bill possession records against the invoice case", context do
    counterpart = Map.put(gstr2b("PORTAL-9"), "vendor_gstin", "27AAPFU0939F1ZV")
    put_month!(context, [], [counterpart])
    {:ok, view, _html} = live(context.conn, review_path(context.client))

    view |> element("#gst-document-held") |> render_click()

    assert event =
             Nila.Repo.get_by!(Nila.Gst.Purchase.ItcCaseEvent,
               event_type: "client_holds_document"
             )

    assert event.decided_by_id == context.user.id
  end

  test "the month surfaces prior-period ITC separately from its register", context do
    prior_books = books("prior-book", %{"invoice_number" => "CARRY-1"})
    prior_recon = Reconciliation.reconcile([prior_books], [])
    prior_rows = Register.rows([prior_books], prior_recon, %{})

    {:ok, _prior_month} =
      Months.upsert(%{
        org_id: context.org.id,
        client_id: context.client.id,
        period: "2026-07",
        state: "worked",
        register_rows: prior_rows,
        recon: prior_recon,
        summary: Register.summary(prior_rows)
      })

    put_month!(context, [], [gstr2b("CARRY-1")])
    {:ok, view, _html} = live(context.conn, "/gst/#{context.client.id}/#{@period}")

    assert has_element?(view, "#gstr3b-carried-itc", "Prior-period ITC")
    assert has_element?(view, "#gstr3b-carried-itc", "Jul 2026")
    assert has_element?(view, "#gstr3b-carried-itc", "Ready to claim in this period")
  end

  test "asking the client drafts the missing-bill message", context do
    put_month!(context, [], [gstr2b("PORTAL-9")])
    {:ok, view, _html} = live(context.conn, review_path(context.client))

    view |> element("#gst-ask-client") |> render_click()

    assert has_element?(view, "#gst-missing-bill-modal")
    assert has_element?(view, "#gst-missing-bill-draft", "Dear Breeze")
    assert has_element?(view, "#gst-missing-bill-draft", "invoice PORTAL-9")
  end

  defp assert_dom_order(view, ids) do
    html = render(view)

    positions =
      Enum.map(ids, fn id ->
        {position, _length} = :binary.match(html, ~s(id="#{id}"))
        position
      end)

    assert positions == Enum.sort(positions)
  end

  defp put_books_without_2b!(context, period, id) do
    documents = [books(id)]
    recon = Reconciliation.reconcile(documents, [])
    rows = Register.rows(documents, recon, %{})

    {:ok, month} =
      Months.upsert(%{
        org_id: context.org.id,
        client_id: context.client.id,
        period: period,
        state: "worked",
        register_rows: rows,
        recon: recon,
        summary: Register.summary(rows, Groups.build(recon))
      })

    month
  end

  defp put_month!(context, books, counterparts) do
    gstr2b_arrived!(context.org, context.client, @period, counterparts)
    recon = Reconciliation.reconcile(books, counterparts)
    rows = Register.rows(books, recon, %{})

    {:ok, month} =
      Months.upsert(%{
        org_id: context.org.id,
        client_id: context.client.id,
        period: @period,
        state: "worked",
        register_rows: rows,
        recon: recon,
        summary: Register.summary(rows, Groups.build(recon))
      })

    month
  end

  defp review_path(client, item \\ nil, scope \\ "needs_you") do
    base = "/gst/#{client.id}/#{@period}/review/purchase?scope=#{scope}"
    if item, do: base <> "&item=#{item}", else: base
  end

  defp books(id, attrs \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "vendor_name" => "Sharma Steels",
        "vendor_gstin" => @gstin,
        "invoice_number" => "INV-001",
        "invoice_date" => ~D[2026-08-05],
        "taxable_paise" => 1_000_000,
        "tax_paise" => %{"cgst" => 90_000, "sgst" => 90_000, "igst" => 0},
        "total_paise" => 1_180_000,
        "images" => []
      },
      attrs
    )
  end

  defp gstr2b(number) do
    %{
      "vendor_name" => "SHARMA STEELS",
      "vendor_gstin" => @gstin,
      "invoice_number" => number,
      "invoice_date" => ~D[2026-08-05],
      "taxable_paise" => 1_000_000,
      "tax_paise" => %{"cgst" => 90_000, "sgst" => 90_000, "igst" => 0},
      "total_paise" => 1_180_000,
      "pos" => "33"
    }
  end
end
