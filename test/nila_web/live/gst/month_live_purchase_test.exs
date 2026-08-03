defmodule NilaWeb.Gst.MonthLivePurchaseTest do
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Nila.GstFixtures

  alias Nila.Clients
  alias Nila.Gst.Filing.{Calendar, Signoffs}
  alias Nila.Gst.Intake.Dumps
  alias Nila.Gst.Purchase.Months, as: ClientMonths
  alias Nila.Gst.Purchase.Register
  alias Nila.Gst.Sales.Months, as: SalesMonths
  alias Nila.Storage

  @dir "tmp/register/breeze-2025-10"
  @period "2025-10"

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()
    client = client_fixture(org)
    client_month = seed_month(org, client)
    confirm_sales_complete!(org, client, @period)

    %{
      conn: log_in_user(conn, user),
      user: user,
      org: org,
      client: client,
      client_month: client_month
    }
  end

  test "purchases open and sales absent: one door, money in the headline", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    need_decision = Nila.Gst.Purchase.Register.stats(read_json("summary.json")).need_decision

    assert has_element?(view, "#month-page")
    assert has_element?(view, "#month-headline", "of it rides on #{need_decision} decisions")
    assert has_element?(view, "#month-door-decisions", "Work the decisions")

    # The losing track is one quiet line, never a second button.
    assert render(view) =~ "Sales bills not in, so the GSTR-1 waits."
    assert doors(view) == ["month-door-decisions"]

    assert has_element?(view, "#month-evidence")
    refute has_element?(view, "#month-support")

    rows = read_rows()
    stats = Nila.Gst.Purchase.Register.stats(read_json("summary.json"))

    # The header counts books invoices, not rows: a 2B-only row is a bill nobody
    # supplied, and calling it extracted credits the client with a document they
    # never sent.
    assert has_element?(
             view,
             "#month-register:not(details)",
             "#{stats.invoices} invoices extracted · #{stats.gstr2b_only} from 2B only"
           )

    refute has_element?(view, "#month-register summary")

    for {row, index} <- Enum.with_index(rows) do
      assert has_element?(view, "##{dom_id(row, index)}")
    end
  end

  test "the headline carries rupees, not only counts", %{conn: conn, client: client, org: org} do
    {:ok, month} = ClientMonths.get_by_period(org.id, client.id, @period)
    workings = Nila.Gst.Purchase.Resolutions.workings(month)
    stats = Nila.Gst.Purchase.Register.stats(workings.summary)

    assert stats.open_tax_paise > 0
    assert stats.matched_tax_paise > 0

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    assert has_element?(
             view,
             "#month-headline",
             Nila.Formatters.format_money(stats.open_tax_paise, prefix: "₹")
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

    # The badge names this card's own object — an open reconciliation — not the
    # GSTR-3B's state, which is what "Blocked" was describing.
    assert has_element?(view, "#gstr3b-verdict", "Needs #{stats.need_decision} decision")

    # The three figures must close: a reader adding the two parts has to land on
    # the whole, or the card teaches an arithmetic that is wrong.
    assert stats.settled_tax_paise + stats.open_tax_paise == stats.total_tax_paise

    for {id, paise} <- [
          {"#gstr3b-total-itc", stats.total_tax_paise},
          {"#gstr3b-open-itc", stats.open_tax_paise},
          {"#gstr3b-settled-itc", stats.settled_tax_paise}
        ] do
      assert has_element?(view, id, Nila.Formatters.format_money(paise, prefix: "₹"))
    end

    assert has_element?(
             view,
             "#gstr3b-review-required",
             "Work the #{stats.need_decision} decisions"
           )
  end

  # The whole open pile is bills nobody sent: no decision on this page can
  # release the credit, so the page must ask for documents instead of pointing a
  # senior at a queue with nothing decidable in it.
  test "a month whose only open rows are uncollected bills asks for them", %{
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

    assert has_element?(view, "#gstr3b-verdict", "Waiting for bills")
    assert has_element?(view, "#gstr3b-request-bills", "Request the #{awaiting} missing bills")
    refute has_element?(view, "#gstr3b-review-required")

    # The money is named for the document it waits on, not for a judgement.
    assert has_element?(view, "#gstr3b-verdict", "Awaiting bills")
    refute render(view) =~ "rides on #{awaiting} decisions"

    # Net ITC is computed off the 2B ceiling, so it counts bills nobody sent.
    # Saying so stops a claim-ready figure standing alone.
    assert has_element?(view, "#gst-3b-unsupported", "has no supplied bill behind it")
    assert has_element?(view, "#month-3b", "GSTR-3B preview")
  end

  # A bill the portal has but nobody supplied is the sharpest completeness
  # signal the purchase side has. It used to exist only as rows in the table.
  test "completeness counts books invoices and 2B-only bills separately", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    rows = read_rows()
    gstr2b_only = Enum.count(rows, &(&1["bucket"] == "in_2b_not_books"))
    assert gstr2b_only > 0

    completeness = view |> element("#gstr3b-completeness") |> render()

    assert completeness =~ "In 2B, bill not supplied"
    assert completeness =~ "Invoices extracted"
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
             "##{dom_id(settled, settled_index)} .truncate",
             settled["verdict"]
           )
  end

  # The return the track assembles belongs with the position it belongs to, not
  # after 58 rows of evidence where nobody reaches it.
  test "the assembled 3B renders inside the purchase track, above the register", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    assert has_element?(view, "#month-register #month-3b #gst-3b-panel")

    html = render(view)
    assert index_of(html, "gstr3b-verdict") < index_of(html, "month-3b")
    assert index_of(html, "month-3b") < index_of(html, "gst-register")
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
    # The note still speaks, because a flag on a matched bill is worth reading.
    assert row_html =~ "truncate"
  end

  test "clicking an open register row lands in the queue on that item", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    {open_row, index} =
      read_rows()
      |> Enum.with_index()
      |> Enum.find(fn {row, _} ->
        is_binary(row["id"]) and row["bucket"] != "matched" and row["accepted_reason"] == nil
      end)

    assert view |> element("##{dom_id(open_row, index)}") |> render() =~
             "/gst/#{client.id}/#{@period}/exceptions?exception=#{open_row["id"]}"
  end

  test "clicking a row with images shows the bill and reason text", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    {row, index} =
      read_rows()
      |> Enum.with_index()
      |> Enum.find(fn {row, _} ->
        row["images"] not in [nil, []] and row["flags"] not in [nil, []] and
          row["bucket"] == "matched"
      end)

    reason = row["flags"] |> hd() |> Map.get("reason")
    verdict = row["flags"] |> hd() |> Map.get("code") |> Nila.Formatters.issue_label()
    selector = "#gst-register ##{dom_id(row, index)}"

    refute has_element?(view, selector, reason)
    assert has_element?(view, "#{selector} .truncate", verdict)

    view |> element(selector) |> render_click()

    assert has_element?(view, "#gst-evidence-modal")
    assert has_element?(view, "#gst-evidence-images img")
    assert render(view) =~ reason
  end

  test "clicking a 2B-only row shows its note without an image", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    {row, index} =
      read_rows()
      |> Enum.with_index()
      |> Enum.find(fn {row, _} -> row["images"] in [nil, []] and row["recon_note"] end)

    selector = "##{dom_id(row, index)}"
    refute has_element?(view, "#gst-register #{selector}", row["recon_note"])

    assert has_element?(
             view,
             "#gst-register #{selector} .truncate",
             "Ask the client for this bill"
           )

    view |> element(selector) |> render_click()

    assert has_element?(view, "#gst-evidence-modal")
    refute has_element?(view, "#gst-evidence-images img")
    assert render(view) =~ row["recon_note"]
  end

  test "the 3B panel shows the ITC side and says the liability is missing", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    assert has_element?(view, "#gst-3b-panel")
    html = render(view)
    assert html =~ "Outward liability needs the month"
    assert html =~ "C Net ITC"
    refute has_element?(view, "#gst-3b-cash")
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

  test "the owning org can fetch an evidence image", %{conn: conn, client: client} do
    conn = get(conn, ~p"/gst/#{client.id}/#{@period}/evidence/page_09.png")

    assert response(conn, 200)
    assert get_resp_header(conn, "content-type") |> hd() =~ "image/png"
  end

  test "logged-out visitors cannot fetch evidence", %{client: client} do
    conn =
      get(Phoenix.ConnTest.build_conn(), ~p"/gst/#{client.id}/#{@period}/evidence/page_09.png")

    assert redirected_to(conn) == "/users/log_in"
  end

  test "another org cannot fetch this org's evidence image", %{client: client} do
    %{user: other_user} = user_with_org_fixture(%{org: %{gstin: "27AAPFU0939F1ZV"}})
    conn = log_in_user(Phoenix.ConnTest.build_conn(), other_user)

    conn = get(conn, ~p"/gst/#{client.id}/#{@period}/evidence/page_09.png")

    assert response(conn, 404)
  end

  test "evidence rejects a basename outside the image whitelist", %{
    conn: conn,
    client: client
  } do
    conn = get(conn, ~p"/gst/#{client.id}/#{@period}/evidence/#{"secret.txt"}")

    assert response(conn, 404)
  end

  test "a dump after filing points to the open month and cannot be released", %{
    conn: conn,
    user: user,
    org: org,
    client: client
  } do
    {:ok, dump} =
      Dumps.record(
        %{org_id: org.id, client_id: client.id, brought_in_by_id: user.id},
        %{period: @period, kind: "purchase", file_keys: ["late/purchase.pdf"]}
      )

    dump = Dumps.mark_after_filing(dump)
    open_period = Calendar.closeable_period(Date.utc_today())

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    # An interrupted pile owns the door: decisions taken on half the documents
    # are worth nothing, so it outranks the 21 open decisions underneath.
    assert has_element?(view, "#month-headline", "Documents arrived after this month was filed")

    assert has_element?(
             view,
             "#month-door-after-filing[href='/gst/upload?client_id=#{client.id}&period=#{open_period}']"
           )

    assert doors(view) == ["month-door-after-filing"]

    assert has_element?(
             view,
             "#month-purchase-sources #month-dump-#{dump.id}",
             "Added after filing"
           )

    assert has_element?(view, "#month-dump-#{dump.id}", "Move it to an open month")

    refute has_element?(view, "#month-dump-release-#{dump.id}")
    refute has_element?(view, "#month-dump-#{dump.id}", "reopen")
  end

  test "owner signs off: banner appears and the month moves to reviewed", %{
    conn: conn,
    client: client,
    org: org
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    refute has_element?(view, "#month-door-sign-3b")
    refute has_element?(view, "#month-exit-gstr3b")

    {:ok, _sales} =
      SalesMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "reviewed",
        cess_evaluated: true,
        invoices: []
      })

    {:ok, month} = ClientMonths.get_by_period(org.id, client.id, @period)

    # Every bucket that leaves a row open, not just the three that happened to
    # be populated when this was written — a value mismatch needs a decision too.
    clean_recon =
      month.recon
      |> Map.put("needs_human", [])
      |> Map.put("in_2b_not_books", [])
      |> Map.put("in_books_not_2b", [])
      |> Map.put("value_mismatch", [])

    {:ok, _} =
      ClientMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "worked",
        register_rows: month.register_rows,
        recon: clean_recon,
        summary: month.summary
      })

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    # Both tracks clear: the door is the signature itself, in filing order,
    # one at a time. The GSTR-1 files on the 11th, so it goes first, and the
    # filing gap outranks the next signature all the way through.
    assert doors(view) == ["month-door-sign-r1"]
    assert has_element?(view, "#month-exit-gstr1 #month-door-sign-r1.btn-primary")
    refute has_element?(view, "#month-verdict #month-door-sign-r1")
    view |> element("#month-door-sign-r1") |> render_click()

    assert doors(view) == ["month-door-file-sales"]
    assert has_element?(view, "#month-door-file-sales[href='#month-exit-gstr1']")
    view |> element("#gstr1-mark-filed") |> render_submit(%{"arn" => "R1-ARN"})

    assert doors(view) == ["month-door-sign-3b"]
    assert has_element?(view, "#month-exit-gstr3b #month-door-sign-3b.btn-primary")
    refute has_element?(view, "#month-verdict #month-door-sign-3b")
    view |> element("#month-door-sign-3b") |> render_click()

    # Signed: the door becomes the filing step and points at the ARN entry.
    assert doors(view) == ["month-door-file-purchase"]
    assert has_element?(view, "#month-door-file-purchase[href='#month-exit-gstr3b']")
    assert has_element?(view, "#month-exit-gstr3b a[target='_blank'][rel='noopener']")
    assert has_element?(view, "#gst-filed-arn")
    refute has_element?(view, "#month-door-sign-3b")
    assert has_element?(view, "#month-exit-gstr3b", "Signed by")

    {:ok, month} = ClientMonths.get_by_period(org.id, client.id, @period)
    assert month.state == "reviewed"
    assert {:ok, signoff} = Signoffs.latest_signoff(month.id)
    assert Map.has_key?(signoff.snapshot, "gstr3b")
  end

  test "a clean worked month points seniors to sign-off and tells members to wait", %{
    conn: conn,
    org: org,
    client: client
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

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    assert has_element?(view, "#month-exit-gstr3b", "Signed by")
    assert has_element?(view, "#gst-register")
    assert has_element?(view, "#month-evidence #month-3b #gst-3b-panel")

    frozen_stats = Nila.Gst.Purchase.Register.stats(frozen["summary"])

    assert has_element?(
             view,
             "#month-register",
             "#{frozen_stats.invoices} invoices extracted"
           )
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
        state: "reviewed",
        cess_evaluated: true
      })

    scope = Nila.Accounts.Scope.for_user(user)
    client_month = settle_register!(client_month, user.id)
    assert {:ok, _} = Signoffs.sign_off_gstr1(sales, scope)
    assert {:ok, _} = Signoffs.sign_off(client_month, scope)
    assert {:ok, _} = Signoffs.mark_filed(sales, scope, "R1-ARN")

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    view
    |> element("#gst-mark-filed")
    |> render_submit(%{"arn" => "3B-ARN"})

    assert render(view) =~ "Month closed."

    assert has_element?(view, "#month-headline", "ARN 3B-ARN. Month closed.")
    assert doors(view) == []
    refute has_element?(view, "#month-deadline")
    assert has_element?(view, "#gst-register")
    assert has_element?(view, "#gst-3b-panel")
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
        state: "reviewed",
        cess_evaluated: true
      })

    scope = Nila.Accounts.Scope.for_user(user)
    client_month = settle_register!(client_month, user.id)
    assert {:ok, _} = Signoffs.sign_off_gstr1(sales, scope)
    assert {:ok, _} = Signoffs.sign_off(client_month, scope)

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    # Purchases win the door, so the chip is the 3B's clock (the 20th), not
    # the GSTR-1's (the 11th) that deadline/4 would have led with.
    assert doors(view) == ["month-door-file-purchase"]
    assert has_element?(view, "#month-deadline", "GSTR-3B")
    assert has_element?(view, "#month-deadline", "due 20 Nov 2025")
    assert has_element?(view, "#month-deadline", "days overdue")
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
        state: "reviewed",
        cess_evaluated: true
      })

    scope = Nila.Accounts.Scope.for_user(user)
    client_month = settle_register!(client_month, user.id)
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

  test "redirects logged-out visitors to log in", %{client: client} do
    assert {:error, {:redirect, %{to: "/users/log_in"}}} =
             live(Phoenix.ConnTest.build_conn(), ~p"/gst/#{client.id}/#{@period}")
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

    for basename <- File.ls!(Path.join(@dir, "images")) do
      bytes = File.read!(Path.join([@dir, "images", basename]))
      key = ClientMonths.evidence_key(org.id, client.id, @period, basename)
      {:ok, _} = Storage.put(key, bytes)
    end

    {:ok, client_month} =
      ClientMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "worked",
        register_rows: read_rows(),
        recon: read_json("recon.json"),
        summary: read_json("summary.json")
      })

    client_month
  end

  defp read_rows, do: read_json("register_rows.json")

  defp read_json(file) do
    @dir |> Path.join(file) |> File.read!() |> Jason.decode!()
  end

  defp dom_id(%{"id" => id}, _index) when is_binary(id), do: "gst-row-#{id}"
  defp dom_id(_row, index), do: "gst-row-idx-#{index}"

  defp index_of(html, id) do
    [start, _rest] = String.split(html, ~s(id="#{id}"), parts: 2)
    String.length(start)
  end

  defp doors(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[id^='month-door-']")
    |> LazyHTML.attribute("id")
  end
end
