defmodule NilaWeb.Gst.MonthLivePurchaseCompactTest do
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Nila.GstFixtures

  alias Nila.Clients
  alias Nila.Gst.Filing.Signoffs
  alias Nila.Gst.Intake.Dumps
  alias Nila.Gst.Purchase.Months, as: ClientMonths
  alias Nila.Gst.Purchase.{Register, Resolutions}
  alias Nila.Gst.Sales.Months, as: SalesMonths

  @dir "tmp/register/breeze-2025-10"
  @period "2025-10"
  @compact_book_ids ~w(d1_inv_01 d1_inv_02 d1_inv_04 d1_inv_07 d1_inv_09 d1_inv_22)

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()
    client = client_fixture(org)
    client_month = seed_month(org, client)

    %{
      conn: log_in_user(conn, user),
      user: user,
      org: org,
      client: client,
      client_month: client_month
    }
  end

  test "purchase reconciliation selection stays an outlined large-card state", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    assert has_element?(
             view,
             "#purchase-score-all[data-selected='true'][aria-pressed='true'] .nila-purchase-scorecard-label"
           )

    view |> element("#purchase-score-matched") |> render_click()

    assert has_element?(
             view,
             "#purchase-score-matched[data-selected='true'][aria-pressed='true']"
           )

    refute has_element?(view, "#purchase-score-all[data-selected='true']")
    assert has_element?(view, "#purchase-score-all[aria-pressed='false']")
  end

  test "the gap between books ITC and the 2B ceiling is a line, not a subtraction", %{
    conn: conn,
    org: org,
    client: client
  } do
    period = "2025-07"
    rows = read_rows()

    # The stored fixture summary predates this field, which is its own correct
    # behaviour (see below). Recomputing gives a live month.
    {:ok, _} =
      ClientMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: period,
        state: "worked",
        register_rows: rows,
        recon: read_json("recon.json"),
        summary: Register.summary(rows)
      })

    stats = rows |> Register.summary() |> Register.stats()

    # The card says "ITC this month" and the bridge says "Reported in GSTR-2B";
    # they differ by exactly the credit the portal never reported. That gap had
    # no name, so a reader could only find it by subtracting two totals that
    # looked like they should agree.
    assert stats.unreported_by_vendor_tax_paise > 0

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{period}")

    assert has_element?(view, "#gstr3b-itc-bridge-books-itc", "Net ITC effect in the register")

    assert has_element?(
             view,
             "#gstr3b-itc-bridge-not-in-2b",
             "Less: not reported in GSTR-2B"
           )

    # And it says what to do about it, because it is the most actionable figure
    # on the page: not claimable this month, and each row is a vendor to chase.
    assert has_element?(view, "#gstr3b-itc-bridge-not-in-2b", "Not claimable this month")
    assert has_element?(view, "#gstr3b-itc-bridge-reported", "Reported in GSTR-2B")
  end

  test "a snapshot with no figure for the gap draws no line for it" do
    # Absent and zero read identically on a summary frozen before the field
    # existed, so the line stays off rather than asserting a confident ₹0. An
    # unsigned month recomputes its summary, so this is the signed-snapshot
    # path and is asserted on the stats directly.
    stats = Register.stats(read_json("summary.json"))

    refute stats.unreported_by_vendor_known?
    assert stats.unreported_by_vendor_tax_paise == 0
  end

  test "pipeline counts are not presented as accounting completeness", %{
    conn: conn,
    org: org,
    client: client
  } do
    # "0 files received" beside "12 invoices extracted" is an impossible pair,
    # and rendering it flat teaches a reviewer to distrust the whole block.
    period = "2025-08"

    {:ok, _} =
      ClientMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: period,
        state: "worked",
        register_rows: read_rows(),
        recon: read_json("recon.json"),
        summary: read_json("summary.json")
      })

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{period}")

    refute has_element?(view, "#gstr3b-completeness")
    assert has_element?(view, "#gstr3b-register")

    # Receiving source files does not bring the telemetry grid back.
    {:ok, seeded, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")
    refute has_element?(seeded, "#gstr3b-completeness")
  end

  test "an ITC figure that cannot be true is not printed as fact", %{
    conn: conn,
    client: client,
    org: org,
    user: user
  } do
    # "₹0 of ITC this month" above a register of a dozen bills is the money-side
    # twin of "0 files received" beside "12 invoices extracted": the counts came
    # through the freeze and the rupees did not, so the panel states a total it
    # never had. A signed month renders from its snapshot, which is the only way
    # a pre-money summary reaches the page — an unsigned one recomputes.
    {:ok, month} = ClientMonths.get_by_period(org.id, client.id, @period)
    scope = Nila.Accounts.Scope.for_user(user)
    month = settle_register!(month, user.id)
    {:ok, _} = Signoffs.sign_off(month, scope)
    {:ok, signoff} = Signoffs.latest_signoff(month.id)

    frozen =
      update_in(
        signoff.snapshot,
        ["summary"],
        &Map.drop(&1, ~w(total_tax_paise matched_tax_paise open_tax_paise))
      )

    signoff
    |> Ecto.Changeset.change(snapshot: frozen)
    |> Nila.Repo.update!()

    stats = Register.stats(frozen["summary"])
    refute stats.itc_money_known?
    assert stats.rows > 0

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    assert has_element?(view, "#gstr3b-itc-position", "not recorded for this month")
    refute has_element?(view, "#gstr3b-itc-position", "₹0")

    # The month that did record its ITC still states it.
    {:ok, _} =
      ClientMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: "2025-06",
        state: "worked",
        register_rows: read_rows(),
        recon: read_json("recon.json"),
        summary: read_json("summary.json")
      })

    {:ok, seeded, _html} = live(conn, ~p"/gst/#{client.id}/2025-06")
    refute has_element?(seeded, "#gstr3b-itc-position", "not recorded for this month")
  end

  test "a reconciled month never claims the 2B is missing", %{
    conn: conn,
    org: org,
    client: client
  } do
    # The page asked the dumps table whether a 2B had arrived. A month
    # reconciled by a seed, a backfill, or an import predating the current
    # pipeline has no dump row — and read "Nothing reconciles until it is in"
    # printed directly above its own rows badged "Matched to 2B".
    period = "2025-09"

    {:ok, _} =
      ClientMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: period,
        state: "worked",
        register_rows: read_rows(),
        recon: read_json("recon.json"),
        summary: read_json("summary.json")
      })

    assert Dumps.list(org.id, client.id, period) == []

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{period}")

    refute render(view) =~ "Nothing reconciles until it is in"
    refute has_element?(view, "#month-door-bring-2b")
    assert has_element?(view, "#gstr3b-itc-bridge")

    # The detailed position belongs to the purchase track rather than being
    # repeated in the month header.
    stats = Register.stats(read_json("summary.json"))
    refute has_element?(view, "#month-headline")
    assert has_element?(view, "#gstr3b-itc-position", "decisions affect")
    assert stats.matched_tax_paise > 0
  end

  test "value mismatches remain disclosed without pretending the position is reconciled", %{
    conn: conn,
    org: org,
    client: client
  } do
    period = "2025-05"

    rows =
      "register_rows.json"
      |> read_fixture_json()
      |> Enum.filter(&(&1["id"] == "d1_inv_04"))

    recon =
      "recon.json"
      |> read_fixture_json()
      |> Map.new(fn
        {"value_mismatch" = bucket, entries} ->
          {bucket, Enum.filter(entries, &(&1["books"]["id"] == "d1_inv_04"))}

        {bucket, _entries} ->
          {bucket, []}
      end)

    assert rows != []
    gstr2b_arrived!(org, client, period)

    {:ok, _} =
      ClientMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: period,
        state: "worked",
        register_rows: rows,
        recon: recon,
        summary: Register.summary(rows)
      })

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{period}")

    assert has_element?(view, "#month-workpaper-tab-purchases", "Differences noted")
    assert has_element?(view, "#gstr3b-itc-position", "value difference")
    assert has_element?(view, "#purchase-open-gstr3b")
    refute has_element?(view, "#gstr3b-review-required")
  end

  test "purchases show decisions and missing bills as parallel work", %{
    conn: conn,
    client: client,
    client_month: client_month
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    need_decision =
      client_month |> Resolutions.workings() |> then(&Register.need_decision(&1.summary))

    assert has_element?(view, "#month-page")
    refute has_element?(view, "#month-headline")
    refute has_element?(view, "#month-verdict #month-door-decisions")

    assert has_element?(view, "#gstr3b-verdict h2.font-display", "Purchases & ITC")
    assert has_element?(view, "#gstr3b-verdict.rounded-box.moonlight-soft")
    refute has_element?(view, "#gstr3b-completeness")
    assert has_element?(view, "#gstr3b-reconciliation h3", "ITC working")

    assert need_decision > 0
    assert has_element?(view, "#gstr3b-review-required", "Review next action")

    refute has_element?(view, "#gstr3b-request-bills")
    assert has_element?(view, "#gstr3b-itc-position", "missing")

    assert purchase_review_hrefs(view) != []
    assert Enum.all?(purchase_review_hrefs(view), &String.contains?(&1, "scope=needs_you"))

    # The other track remains visible, but the header does not duplicate the
    # purchase action.
    assert render(view) =~ "Sales bills not in, so the GSTR-1 waits."
    assert doors(view) == []

    assert has_element?(view, "#month-evidence")
    refute has_element?(view, "#month-support")

    rows = read_rows()
    stats = rows |> Register.summary() |> Register.stats()

    # The header counts books invoices, not rows: a 2B-only row is a bill nobody
    # supplied, and calling it extracted credits the client with a document they
    # never sent.
    assert has_element?(
             view,
             "#month-register:not(details)",
             "#{stats.rows} of #{stats.rows} positions shown"
           )

    assert has_element?(
             view,
             "#month-register:not(details)",
             "#{stats.invoices} supplied documents · #{stats.gstr2b_only} additional 2B-only entries"
           )

    assert has_element?(view, "#gstr3b-register #gst-register")

    for {row, index} <- Enum.with_index(rows) do
      assert has_element?(view, "##{dom_id(row, index)}")
    end
  end

  test "the purchase position carries rupees, not only counts", %{
    conn: conn,
    client: client,
    org: org
  } do
    {:ok, month} = ClientMonths.get_by_period(org.id, client.id, @period)
    workings = Nila.Gst.Purchase.Resolutions.workings(month)
    stats = Nila.Gst.Purchase.Register.stats(workings.summary)

    assert stats.open_tax_paise > 0
    assert stats.matched_tax_paise > 0

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    decision_tax = stats.decision_tax_paise + stats.value_dispute_tax_paise

    assert has_element?(
             view,
             "#gstr3b-itc-position",
             Nila.Formatters.format_money(decision_tax, prefix: "₹")
           )

    assert has_element?(
             view,
             "#gstr3b-itc-position",
             Nila.Formatters.format_money(stats.awaiting_bills_tax_paise, prefix: "₹")
           )
  end

  test "the purchase track states its own ITC position, not only the month band", %{
    conn: conn,
    client: client,
    org: org
  } do
    {:ok, month} = ClientMonths.get_by_period(org.id, client.id, @period)

    stats =
      Nila.Gst.Purchase.Register.stats(Nila.Gst.Purchase.Resolutions.workings(month).summary)

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    assert stats.settled_tax_paise + stats.open_tax_paise == stats.total_tax_paise

    assert has_element?(
             view,
             "#gstr3b-itc-position",
             Nila.Formatters.format_money(stats.settled_tax_paise, prefix: "₹")
           )

    assert has_element?(
             view,
             "#gstr3b-itc-position",
             Nila.Formatters.format_money(
               stats.decision_tax_paise + stats.value_dispute_tax_paise,
               prefix: "₹"
             )
           )

    assert has_element?(view, "#gstr3b-itc-position", "settled")
    assert has_element?(view, "#gstr3b-itc-position", "decisions affect")
    assert has_element?(view, "#gstr3b-itc-position", "missing")

    assert stats.need_decision > 0
    assert has_element?(view, "#gstr3b-review-required", "Review next action")
  end

  # The register waits on bills, while the return needs one possession
  # decision per supply before it can claim the reported credit.
  test "a month whose only open rows are uncollected bills asks for possession", %{
    conn: conn,
    org: org,
    client: client
  } do
    {:ok, month} = ClientMonths.get_by_period(org.id, client.id, @period)

    collection_only =
      month.recon
      |> Map.put("needs_human", [])
      |> Map.put("in_books_not_2b", [])
      |> Map.put("value_mismatch", [])

    rows = Nila.Gst.Purchase.Register.rows([], collection_only, %{})

    {:ok, _} =
      ClientMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "worked",
        register_rows: rows,
        recon: collection_only,
        summary: Nila.Gst.Purchase.Register.summary(rows)
      })

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    awaiting = length(collection_only["in_2b_not_books"])
    assert awaiting > 0

    assert has_element?(view, "#gstr3b-review-required")
    assert has_element?(view, "#gstr3b-itc-position", "missing")
    refute has_element?(view, "#month-verdict #month-door-decisions")

    # The return remains available as its own workpaper while evidence is collected.
    refute has_element?(view, "#month-3b")
    view |> element("#month-workpaper-tab-gstr3b") |> render_click()
    assert has_element?(view, "#month-3b", "Proposed GSTR-3B")
  end

  # A bill the portal has but nobody supplied is the sharpest completeness
  # signal the purchase side has. It used to exist only as rows in the table.
  test "the accounting position replaces the old completeness telemetry", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    rows = read_rows()
    gstr2b_only = Enum.count(rows, &(&1["bucket"] == "in_2b_not_books"))
    assert gstr2b_only > 0

    refute has_element?(view, "#gstr3b-completeness")

    assert has_element?(view, "#gstr3b-register", "#{gstr2b_only} additional 2B-only entries")
    view |> element("#month-workpaper-tab-gstr3b") |> render_click()

    refute has_element?(view, "#gstr3b-control-itc #gstr3b-itc-supporting-evidence")
    assert has_element?(view, "#gstr3b-open-purchases", "Open Purchases & ITC")

    refute render(view) =~ "complete register"
  end

  # The pill is a matching verdict, but green beside "GSTIN doesn't check out"
  # reads as "reviewed and safe". Only a match the flags cannot dispute keeps
  # the green — and a flag the 2B already answered keeps its note but loses the
  # alarm, or 41% of the register reads "needs review" and none of it lands.
  test "a matched row is alarmed only for flags the 2B cannot answer", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    rows_with_index = Enum.with_index(read_rows())

    find = fn predicate -> Enum.find(rows_with_index, fn {row, _} -> predicate.(row) end) end

    {flagged, flagged_index} =
      find.(&(&1["bucket"] == "matched" and Register.needs_review?(&1)))

    {clean, clean_index} =
      find.(&(&1["bucket"] == "matched" and (&1["flags"] || []) == []))

    # A matched row whose only flags the 2B already settled: quiet pill, live note.
    {settled, settled_index} =
      find.(fn row ->
        row["bucket"] == "matched" and (row["flags"] || []) != [] and
          not Register.needs_review?(row)
      end)

    flagged_html = view |> element("##{dom_id(flagged, flagged_index)}") |> render()
    assert flagged_html =~ "Matched · needs review"

    clean_html = view |> element("##{dom_id(clean, clean_index)}") |> render()
    assert clean_html =~ "Matched to 2B"
    refute clean_html =~ "needs review"

    refute view |> element("##{dom_id(settled, settled_index)}") |> render() =~ "needs review"

    assert has_element?(
             view,
             "##{dom_id(settled, settled_index)} .wrap-break-word",
             settled["verdict"]
           )
  end

  test "an open row shows the move it waits on, not just what is wrong", %{
    conn: conn,
    org: org,
    client: client
  } do
    rows = read_rows()

    # An `in_books_not_2b` row: open, carrying a follow-up, and settleable from
    # the queue with one click, so the settled half of this test can be reached.
    {open, index} =
      rows
      |> Enum.with_index()
      |> Enum.find(fn {row, _i} ->
        Register.open_row?(row) and row["bucket"] == "in_books_not_2b" and
          is_binary(row["id"]) and is_binary(row["next_action"])
      end)

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    # The row already knew the next move; the register printed only the verdict,
    # so a reviewer deciding whether to leave for the queue read the problem
    # with the answer one screen away.
    html = view |> element("##{dom_id(open, index)}") |> render()
    assert html =~ "#{open["verdict"]}"

    assert has_element?(
             view,
             "##{dom_id(open, index)} .wrap-break-word",
             String.slice(open["next_action"], 0, 40)
           )

    refute has_element?(view, "##{dom_id(open, index)} td.max-w-sm .truncate")

    # And once it is decided the note goes quiet altogether — a move printed
    # under a settled bill reads as an instruction to redo it. The follow-up
    # hangs off `annotated_row?`, the same predicate the verdict already uses,
    # rather than a second rule that could drift from it.
    {:ok, review, _html} =
      live(
        conn,
        ~p"/gst/#{client.id}/#{@period}/review/purchase?item=#{open["id"]}&scope=needs_you"
      )

    review |> element("#gst-accept-await-2b") |> render_click()

    {:ok, month} = ClientMonths.get_by_period(org.id, client.id, @period)

    decided =
      month
      |> Nila.Gst.Purchase.Resolutions.workings()
      |> Map.fetch!(:rows)
      |> Enum.find(&(&1["id"] == open["id"]))

    refute Register.annotated_row?(decided)

    {:ok, after_decision, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    refute after_decision
           |> element("##{dom_id(open, index)}")
           |> render() =~ String.slice(open["next_action"], 0, 40)
  end

  test "a provisional 3B leads with Nila's current treatment rather than the undecided ceiling",
       %{
         conn: conn,
         client: client,
         client_month: client_month
       } do
    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=gstr3b")
    workings = Resolutions.workings(client_month)

    refute has_element?(view, "#gstr3b-itc-position")
    refute has_element?(view, "#gst-register")
    assert has_element?(view, "#month-3b", "Proposed GSTR-3B")
    assert has_element?(view, "#gstr3b-preview-status", "Provisional")
    assert has_element?(view, "#gst-3b-cash-pending", "Pending")

    assert has_element?(
             view,
             "#gst-3b-current-itc",
             Nila.Formatters.format_money_with_paise(workings.itc["claimable_paise"])
           )

    refute has_element?(view, "#gst-3b-filing-detail")

    assert has_element?(view, "#month-workpaper-tab-gstr3b[aria-current='page']")
    assert has_element?(view, "#gstr3b-primary-blocker", "Review decisions")
    refute has_element?(view, "#gstr3b-blocker-action-decisions")
    assert has_element?(view, "#gstr3b-blocker-action-no-sales", "Bring in sales bills")
  end

  test "the ⚠ and the row accent are spent only on rows needing a decision", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    {flagged_matched, index} =
      read_rows()
      |> Enum.with_index()
      |> Enum.find(fn {row, _} ->
        row["bucket"] == "matched" and row["flags"] not in [nil, []]
      end)

    row_html = view |> element("##{dom_id(flagged_matched, index)}") |> render()

    refute row_html =~ "hero-exclamation-triangle-mini"
    refute row_html =~ "border-l-warning"
    # The note still speaks in full, because a flag on a matched bill is worth reading.
    assert row_html =~ "wrap-break-word"
    refute row_html =~ "truncate"
  end

  test "clicking an open register row patches the mounted month into purchase review", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")
    month_pid = view.pid

    {open_row, index} =
      read_rows()
      |> Enum.with_index()
      |> Enum.find(fn {row, _} ->
        is_binary(row["id"]) and row["bucket"] != "matched" and row["accepted_reason"] == nil
      end)

    view |> element("##{dom_id(open_row, index)}") |> render_click()

    assert_patch(
      view,
      ~p"/gst/#{client.id}/#{@period}/review/purchase?item=#{open_row["id"]}&scope=needs_you"
    )

    assert view.pid == month_pid
    assert has_element?(view, "#purchase-review")
    assert has_element?(view, "#month-page")
  end

  test "a settled row opens All with evidence and challenge available", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    {row, index} =
      read_rows()
      |> Enum.with_index()
      |> Enum.find(fn {row, _} ->
        row["images"] not in [nil, []] and row["bucket"] == "matched"
      end)

    view |> element("#gst-register ##{dom_id(row, index)}") |> render_click()

    assert_patch(
      view,
      ~p"/gst/#{client.id}/#{@period}/review/purchase?item=#{row["id"]}&scope=all"
    )

    assert has_element?(view, "#gst-exception-evidence-frame img")
    assert has_element?(view, "#gst-challenge-match", "Challenge this match")
  end

  test "a 2B-only row opens the separate documents-to-collect section", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    {row, index} =
      read_rows()
      |> Enum.with_index()
      |> Enum.find(fn {row, _} -> row["bucket"] == "in_2b_not_books" end)

    view |> element("##{dom_id(row, index)}") |> render_click()

    assert has_element?(view, "#gst-exception-queue", "Documents to collect")
    assert has_element?(view, "#gst-ask-client")
    refute has_element?(view, "#gst-exception-evidence-frame")
  end

  test "missing sales liability is stated inside the provisional 3B preview", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=gstr3b")

    assert render(view) =~ "Sales bills not in, so the GSTR-1 waits."
    assert has_element?(view, "#gst-3b-position", "Pending GSTR-1")
    assert has_element?(view, "#gst-3b-cash-pending", "Pending outward tax")
  end

  test "the sales section renders on the same page when a sales month exists", %{
    conn: conn,
    org: org,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")
    assert render(view) =~ "Sales bills not in, so the GSTR-1 waits."
    refute has_element?(view, "#month-sales")

    {:ok, _} =
      Nila.Gst.Sales.Months.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "worked",
        invoices: [],
        derived_gstr1: %{},
        issues: [],
        summary: %{}
      })

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    assert has_element?(view, "#month-sales")
    refute has_element?(view, "#month-sales-missing")
  end

  test "a clean worked month points seniors to sign-off and tells members to wait", %{
    conn: conn,
    org: org,
    client: client,
    user: user
  } do
    {:ok, _purchase} =
      ClientMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "worked",
        register_rows: [],
        recon: %{},
        summary: %{"buckets" => %{"matched" => 0}}
      })

    {:ok, sales} =
      SalesMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "worked"
      })

    # An invoice-less month is still asked what it cannot see for itself, so it
    # is not "clean" until somebody has answered. Answering is a resolution, and
    # recording one puts the month back to "worked" — so the reviewed state is
    # asserted after the answers, not before.
    answer_sales_issues!(sales, user.id)

    {:ok, _sales} =
      SalesMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "reviewed"
      })

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")
    assert doors(view) == ["month-door-sign-r1"]

    # Same state, different role: a signature is not live work for a junior,
    # so the page offers them nothing to press.
    member = user_fixture()
    {:ok, _} = Nila.Orgs.add_user(org, member.id, "member")
    member_conn = log_in_user(Phoenix.ConnTest.build_conn(), member)

    {:ok, member_view, _html} = live(member_conn, ~p"/gst/#{client.id}/#{@period}")
    assert has_element?(member_view, "#month-headline", "Waiting on a senior to sign.")
    assert doors(member_view) == []
  end

  test "a signed month discloses missing evidence without offering a locked review action", %{
    conn: conn,
    org: org,
    client: client,
    user: user
  } do
    period = "2025-04"

    rows =
      "register_rows.json"
      |> read_fixture_json()
      |> Enum.filter(&(&1["bucket"] == "in_2b_not_books"))
      |> Enum.take(1)

    recon =
      "recon.json"
      |> read_fixture_json()
      |> Map.new(fn
        {"in_2b_not_books" = bucket, entries} -> {bucket, Enum.take(entries, 1)}
        {bucket, _entries} -> {bucket, []}
      end)

    gstr2b_arrived!(org, client, period)

    {:ok, month} =
      ClientMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: period,
        state: "worked",
        register_rows: rows,
        recon: recon,
        summary: Register.summary(rows)
      })

    month =
      month
      |> Resolutions.workings()
      |> Map.fetch!(:document_cases)
      |> Enum.reduce(month, fn itc_case, current_month ->
        {:ok, result} =
          Resolutions.record_itc_case_event_and_refresh(
            current_month,
            itc_case.case_id,
            "client_holds_document",
            [],
            user.id
          )

        result.month
      end)

    stats = month |> Resolutions.workings() |> Map.fetch!(:summary) |> Register.stats()
    assert stats.need_decision == 0
    assert stats.awaiting_bills == 1

    assert {:ok, _} = Signoffs.sign_off(month, Nila.Accounts.Scope.for_user(user))

    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{period}?track=purchases")

    assert has_element?(view, "#month-workpaper-tab-purchases", "Position frozen")
    assert has_element?(view, "#gstr3b-itc-position", "1 supporting document still missing")
    assert has_element?(view, "#purchase-open-gstr3b")
    refute has_element?(view, "#gstr3b-request-bills")
  end

  test "a signed month renders from the frozen snapshot, not live derivation", %{
    conn: conn,
    client: client,
    org: org,
    user: user
  } do
    {:ok, month} = ClientMonths.get_by_period(org.id, client.id, @period)
    scope = Nila.Accounts.Scope.for_user(user)
    month = settle_register!(month, user.id)
    {:ok, _} = Signoffs.sign_off(month, scope)
    {:ok, signoff} = Signoffs.latest_signoff(month.id)

    frozen = put_in(signoff.snapshot, ["summary", "buckets", "matched"], 999)

    signoff
    |> Ecto.Changeset.change(snapshot: frozen)
    |> Nila.Repo.update!()

    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=gstr3b")

    assert has_element?(view, "#month-exit-gstr3b", "Signed by")
    refute has_element?(view, "#gst-register")
    assert has_element?(view, "#month-evidence #month-3b #gst-3b-position")

    frozen_stats = Nila.Gst.Purchase.Register.stats(frozen["summary"])

    assert has_element?(view, "#month-workpaper-tab-purchases", "Position frozen")

    view |> element("#month-workpaper-tab-purchases") |> render_click()

    assert has_element?(
             view,
             "#month-register",
             "#{frozen_stats.invoices} supplied documents"
           )

    assert has_element?(view, "#purchase-open-gstr3b")
    refute has_element?(view, "#gstr3b-request-bills")
  end

  test "filing the second return closes the month and points back to Today", %{
    conn: conn,
    org: org,
    user: user,
    client: client,
    client_month: client_month
  } do
    {:ok, sales} =
      SalesMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "reviewed"
      })

    scope = Nila.Accounts.Scope.for_user(user)
    client_month = settle_register!(client_month, user.id)
    answer_sales_issues!(sales, user.id)
    assert {:ok, _} = Signoffs.sign_off_gstr1(sales, scope)
    assert {:ok, _} = Signoffs.sign_off(client_month, scope)
    assert {:ok, _} = Signoffs.mark_filed(sales, scope, "R1-ARN")

    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=gstr3b")

    view
    |> element("#gst-mark-filed")
    |> render_submit(%{"arn" => "3B-ARN"})

    assert render(view) =~ "Month closed."

    assert has_element?(view, "#month-headline", "ARN 3B-ARN. Month closed.")
    assert doors(view) == []
    refute has_element?(view, "#month-deadlines")
    refute has_element?(view, "#gst-register")
    assert has_element?(view, "#gst-3b-position")
    assert has_element?(view, "#gst-filed-note", "Filed")
    refute has_element?(view, "#gst-mark-filed")
    refute has_element?(view, "#gst-reopen-signoff")
  end

  test "a signed-unfiled month leads with the filing gap and its own return's clock", %{
    conn: conn,
    org: org,
    user: user,
    client: client,
    client_month: client_month
  } do
    {:ok, sales} =
      SalesMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "reviewed"
      })

    scope = Nila.Accounts.Scope.for_user(user)
    client_month = settle_register!(client_month, user.id)
    answer_sales_issues!(sales, user.id)
    assert {:ok, _} = Signoffs.sign_off_gstr1(sales, scope)
    assert {:ok, _} = Signoffs.sign_off(client_month, scope)

    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=gstr3b")

    # The month masthead keeps both unfiled return clocks visible; filing belongs to this workpaper.
    assert doors(view) == []
    assert has_element?(view, "#gstr3b-primary-filing")
    assert has_element?(view, "#month-deadline-sales", "GSTR-1")
    assert has_element?(view, "#month-deadline-purchase", "GSTR-3B")
    assert has_element?(view, "#month-deadline-purchase", "due 20 Nov 2025")
    assert has_element?(view, "#month-deadline-purchase", "days overdue")
    assert render(view) =~ "GSTR-1 signed, not yet on the portal."
  end

  test "matched rows without flags render a silent note column", %{conn: conn, client: client} do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    {row, index} =
      read_rows()
      |> Enum.with_index()
      |> Enum.find(fn {row, _} ->
        row["bucket"] == "matched" and row["flags"] in [nil, []]
      end)

    refute view |> element("##{dom_id(row, index)}") |> render() =~ "matched on"
  end

  test "filing GSTR-1 second also closes the month", %{
    conn: conn,
    org: org,
    user: user,
    client: client,
    client_month: client_month
  } do
    {:ok, sales} =
      SalesMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "reviewed"
      })

    scope = Nila.Accounts.Scope.for_user(user)
    client_month = settle_register!(client_month, user.id)
    answer_sales_issues!(sales, user.id)
    assert {:ok, _} = Signoffs.sign_off_gstr1(sales, scope)
    assert {:ok, _} = Signoffs.sign_off(client_month, scope)
    assert {:ok, _} = Signoffs.mark_filed(client_month, scope, "3B-ARN")

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    view
    |> element("#gstr1-mark-filed")
    |> render_submit(%{"arn" => "R1-ARN"})

    assert render(view) =~ "Month closed."
    assert has_element?(view, "#month-headline", "Month closed.")
  end

  test "the operator (member) does not see the sign-off button and cannot sign", %{
    client: client,
    org: org
  } do
    member = user_fixture()
    {:ok, _} = Nila.Orgs.add_user(org, member.id, "member")
    conn = log_in_user(Phoenix.ConnTest.build_conn(), member)

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    refute has_element?(view, "#month-door-sign-3b")
    refute has_element?(view, "#month-door-sign-r1")

    render_click(view, "3b-sign-off", %{})
    assert render(view) =~ "permission"

    {:ok, month} = ClientMonths.get_by_period(org.id, client.id, @period)
    assert month.state == "worked"
  end

  defp client_fixture(org) do
    {:ok, client} =
      Clients.create_client(%{org_id: org.id, name: "Breeze Tech", type: "company"})

    client
  end

  # The recon on disk was produced against a real 2B, so the arrival has to be
  # on record too — without it the month is (correctly) "no 2B in", and every
  # open row is an artifact rather than a decision.
  defp seed_month(org, client) do
    gstr2b_arrived!(org, client, @period)
    rows = read_rows()

    {:ok, client_month} =
      ClientMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "worked",
        register_rows: rows,
        recon: read_json("recon.json"),
        summary: Register.summary(rows)
      })

    client_month
  end

  defp read_rows do
    rows = read_fixture_json("register_rows.json")

    Enum.filter(rows, &(&1["id"] in @compact_book_ids)) ++
      (rows |> Enum.filter(&(&1["bucket"] == "in_2b_not_books")) |> Enum.take(2))
  end

  defp read_json("recon.json") do
    read_fixture_json("recon.json")
    |> Map.new(fn
      {"in_2b_not_books" = bucket, entries} ->
        {bucket, Enum.take(entries, 2)}

      {bucket, entries} ->
        {bucket, Enum.filter(entries, &(&1["books"]["id"] in @compact_book_ids))}
    end)
  end

  defp read_json(file), do: read_fixture_json(file)

  defp read_fixture_json(file) do
    @dir |> Path.join(file) |> File.read!() |> Jason.decode!()
  end

  defp dom_id(%{"id" => id}, _index) when is_binary(id), do: "gst-row-#{id}"
  defp dom_id(_row, index), do: "gst-row-idx-#{index}"

  defp doors(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[id^='month-door-']")
    |> LazyHTML.attribute("id")
  end

  defp purchase_review_hrefs(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("a[href*='/review/purchase?'][href*='scope=needs_you']")
    |> LazyHTML.attribute("href")
  end
end
