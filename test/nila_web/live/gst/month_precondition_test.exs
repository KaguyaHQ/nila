defmodule NilaWeb.Gst.MonthPreconditionTest do
  use NilaWeb.ConnCase, async: true
  use Oban.Testing, repo: Nila.Repo

  import Phoenix.LiveViewTest

  alias Nila.Clients
  alias Nila.Gst.Intake.{DumpWorker, Dumps}
  alias Nila.Gst.Purchase.Months, as: ClientMonths

  @period "2026-06"

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()
    {:ok, client} = Clients.create_client(%{org_id: org.id, name: "Caltech", type: "company"})

    %{conn: log_in_user(conn, user), user: user, org: org, client: client}
  end

  defp in_question(context, finding \\ nil, kind \\ "purchase") do
    {:ok, dump} =
      Dumps.record(
        %{
          org_id: context.org.id,
          client_id: context.client.id,
          brought_in_by_id: context.user.id
        },
        %{
          period: @period,
          kind: kind,
          status: "extracted",
          file_keys: ["dumps/april.pdf"],
          invoices: invoices()
        }
      )

    Dumps.mark_needs_confirmation(dump, finding || full_finding())
  end

  defp invoices do
    for i <- 1..14 do
      %{
        "id" => "d1_#{i}",
        "invoice_number" => "APR-#{i}",
        "invoice_date" => "2026-04-0#{rem(i, 9) + 1}",
        "vendor_name" => "Dawn Power",
        "images" => []
      }
    end
  end

  defp full_finding do
    %{
      "kind" => "cross_month_duplicate",
      "kinds" => ["cross_month_duplicate", "period_mismatch"],
      "total" => 14,
      "outside_period" => 14,
      "modal_period" => "2026-04",
      "outside_periods" => ["2026-01", "2026-02", "2026-03", "2026-04"],
      "duplicate_of" => %{"period" => "2026-04", "count" => 14},
      "severity" => "error",
      "period" => @period
    }
  end

  # The page's weight rule as an assertion: at most one saturated control.
  defp saturated(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(".btn-primary")
    |> LazyHTML.attribute("id")
  end

  test "the question is the month's state, and it is the only thing to answer", context do
    _dump = in_question(context)

    {:ok, view, _html} = live(context.conn, ~p"/gst/#{context.client.id}/#{@period}")

    # The verdict block carries the question, in the verdict's own weight.
    assert has_element?(
             view,
             "#month-headline",
             "All 14 bills in this packet are dated Jan–Apr 2026"
           )

    assert has_element?(view, "#month-headline", "not Jun 2026")
    assert has_element?(view, "#month-headline", "All 14 of them are already in Apr 2026")

    # Three answers, no default, and nothing saturated to pull the eye to one.
    assert has_element?(view, "#month-precondition-choose-move", "Move it to Apr 2026")
    assert has_element?(view, "#month-precondition-choose-keep", "Keep it in Jun 2026")
    assert has_element?(view, "#month-precondition-choose-discard", "Discard it")
    assert saturated(view) == []

    # And no door into the exceptions queue: a month cannot be worked while its
    # inputs are in question.
    refute has_element?(view, "#month-door-decisions")
    refute render(view) =~ "/exceptions"
  end

  test "a dates-only question never scolds: no alarm tone", context do
    _dump =
      in_question(context, %{
        "kind" => "period_mismatch",
        "kinds" => ["period_mismatch"],
        "total" => 14,
        "outside_period" => 11,
        "modal_period" => "2026-04",
        "outside_periods" => ["2026-04"],
        "period" => @period
      })

    {:ok, view, _html} = live(context.conn, ~p"/gst/#{context.client.id}/#{@period}")

    assert has_element?(
             view,
             "#month-headline",
             "11 of this packet's 14 bills are dated Apr 2026, not Jun 2026."
           )

    refute has_element?(view, "#month-headline.text-error")
  end

  test "a duplicate of a filed month says what it cost, in alarm", context do
    _dump = in_question(context)

    {:ok, view, _html} = live(context.conn, ~p"/gst/#{context.client.id}/#{@period}")

    assert has_element?(
             view,
             "#month-headline",
             "Apr 2026 is filed, so those are already declared."
           )

    assert has_element?(view, "#month-headline.text-error")
  end

  # The grade the old flat error got wrong: two unfiled drafts holding the same
  # packet is a question about which one is misplaced, and red is a claim about
  # a consequence that has not happened.
  test "a duplicate of an unfiled month asks instead of scolding", context do
    _dump =
      in_question(context, %{
        "kind" => "cross_month_duplicate",
        "kinds" => ["cross_month_duplicate"],
        "total" => 14,
        "duplicate_of" => %{"period" => "2026-04", "count" => 14},
        "severity" => "question",
        "period" => @period
      })

    {:ok, view, _html} = live(context.conn, ~p"/gst/#{context.client.id}/#{@period}")

    assert has_element?(
             view,
             "#month-headline",
             "Apr 2026 is not filed, so nothing has been declared twice yet"
           )

    assert has_element?(view, "#month-headline", "one of the two copies is in the wrong month")
    refute has_element?(view, "#month-headline.text-error")
  end

  # A finding written before the grade was derived knows nothing about the other
  # month, so the headline says nothing about it either.
  test "a finding with no severity keeps the red and invents no reason", context do
    _dump =
      in_question(context, %{
        "kind" => "cross_month_duplicate",
        "kinds" => ["cross_month_duplicate"],
        "total" => 14,
        "duplicate_of" => %{"period" => "2026-04", "count" => 14},
        "period" => @period
      })

    {:ok, view, _html} = live(context.conn, ~p"/gst/#{context.client.id}/#{@period}")

    assert has_element?(view, "#month-headline", "already in Apr 2026")
    assert has_element?(view, "#month-headline.text-error")
    refute render(view) =~ "is filed, so those are already declared"
    refute render(view) =~ "is not filed"
  end

  test "choosing an answer reveals what that answer needs, and only then a door", context do
    _dump = in_question(context)

    {:ok, view, _html} = live(context.conn, ~p"/gst/#{context.client.id}/#{@period}")

    view |> element("#month-precondition-choose-keep") |> render_click()

    assert has_element?(view, "#month-precondition-reason")
    assert saturated(view) == ["month-precondition-confirm"]

    view |> element("#month-precondition-back") |> render_click()
    assert has_element?(view, "#month-precondition-answers")
    assert saturated(view) == []
  end

  test "keeping it records the reason and hands the packet back to the worker", context do
    dump = in_question(context)

    {:ok, view, _html} = live(context.conn, ~p"/gst/#{context.client.id}/#{@period}")

    view |> element("#month-precondition-choose-keep") |> render_click()

    view
    |> form("#month-precondition-form", %{"reason" => "Availing these credits in June"})
    |> render_submit()

    {:ok, kept} = Dumps.fetch(context.org.id, dump.id)
    assert kept.status == "extracted"
    assert kept.meta["precondition_answer"]["reason"] == "Availing these credits in June"
    assert_enqueued(worker: DumpWorker, args: %{dump_id: dump.id})

    # The reason outlives the question, in the paper trail.
    assert has_element?(
             view,
             "#month-arrived-answer-#{dump.id}",
             "Confirmed as this month's: Availing these credits in June"
           )
  end

  test "keeping it without a reason is refused", context do
    dump = in_question(context)

    {:ok, view, _html} = live(context.conn, ~p"/gst/#{context.client.id}/#{@period}")

    view |> element("#month-precondition-choose-keep") |> render_click()
    view |> form("#month-precondition-form", %{"reason" => "  "}) |> render_submit()

    assert render(view) =~ "Say why this packet belongs here."
    assert {:ok, %{status: "needs_confirmation"}} = Dumps.fetch(context.org.id, dump.id)
  end

  test "moving it repoints the packet and opens the month it belongs to", context do
    dump = in_question(context)

    {:ok, view, _html} = live(context.conn, ~p"/gst/#{context.client.id}/#{@period}")

    view |> element("#month-precondition-choose-move") |> render_click()

    # The destination the data itself names is pre-filled — a fact, not an
    # answer — and every option says what that month already holds.
    html = view |> element("#month-precondition-form") |> render()
    assert html =~ ~s(selected="" value="2026-04")
    refute html =~ ~s(value="#{@period}")

    view |> form("#month-precondition-form", %{"period" => "2026-04"}) |> render_submit()

    assert_redirect(view, "/gst/#{context.client.id}/2026-04")

    {:ok, moved} = Dumps.fetch(context.org.id, dump.id)
    assert moved.period == "2026-04"
    assert moved.status == "extracted"
    assert moved.meta["precondition_answer"]["moved_from"] == @period
    assert_enqueued(worker: DumpWorker, args: %{dump_id: dump.id})
  end

  test "discarding it is terminal and builds no month", context do
    dump = in_question(context)

    {:ok, view, _html} = live(context.conn, ~p"/gst/#{context.client.id}/#{@period}")

    view |> element("#month-precondition-choose-discard") |> render_click()
    view |> form("#month-precondition-form", %{}) |> render_submit()

    {:ok, discarded} = Dumps.fetch(context.org.id, dump.id)
    assert discarded.status == "discarded"

    assert {:error, :not_found} =
             ClientMonths.get_by_period(context.org.id, context.client.id, @period)

    refute has_element?(view, "#month-precondition")
    assert has_element?(view, "#month-arrived-answer-#{dump.id}", "Discarded as a double upload")
    refute_enqueued(worker: DumpWorker)
  end

  # A packet of bills you received and a packet of invoices you raised are not
  # the same noun, and the reason a reviewer is asked to write is not the same
  # sentence. The question is one paragraph — if it describes the wrong side of
  # the ledger, it is describing someone else's month.
  test "the question reads as sales when a sales packet raised it", context do
    _dump = in_question(context, nil, "sales")

    {:ok, view, _html} = live(context.conn, ~p"/gst/#{context.client.id}/#{@period}")

    assert has_element?(view, "#month-precondition", "The sales packet that arrived")
    assert has_element?(view, "#month-headline", "All 14 invoices in this packet are dated")
    refute has_element?(view, "#month-headline", "bills")

    view |> element("#month-precondition-choose-keep") |> render_click()

    refute has_element?(view, "#month-precondition-reason[placeholder*='credits']")
    assert has_element?(view, "#month-precondition-reason[placeholder*='Raised late']")
  end
end
