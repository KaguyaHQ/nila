defmodule NilaWeb.Components.Gst.Month.Verdict do
  use NilaWeb, :html

  alias NilaWeb.Components.Gst.Month.ClientSwitcher

  @moduledoc """
  Resolves the two GST tracks into a compact month status and contextual action.

  The workbench keeps the complete evidence visible regardless of lifecycle;
  this component only states what is blocking or due and offers the one action
  that belongs with that status.
  """

  alias Nila.Formatters
  alias Nila.Gst.Filing.Calendar
  alias Nila.Gst.Intake.Dumps
  alias Nila.Gst.WorkQueue

  @doc """
  Resolves the facts of a month into `%{headline, tone, quiet, door, deadline, deadlines}`.

  Kept separate from the markup so the state table is testable as data rather
  than by scraping HTML.
  """
  def resolve(facts) do
    facts
    |> door_and_headline()
    |> Map.put(:quiet, quiet_lines(facts))
    |> put_deadline(facts)
    |> put_deadlines(facts)
  end

  # 0/1. A packet in question, then interrupted piles.
  defp door_and_headline(%{attention_dumps: dumps} = facts) when dumps != [] do
    cond do
      dump = find_dump(dumps, "needs_confirmation") ->
        question(facts, dump)

      dump = find_dump(dumps, "failed") ->
        %{
          tone: :alarm,
          headline: "A pile failed to extract. The month is working off partial documents.",
          door: %{
            id: "month-door-failed-pile",
            label: "See what happened",
            kind: :anchor,
            to: source_anchor(dump.kind)
          },
          dump: dump
        }

      (dump = find_dump(dumps, "held")) && releasable?(facts, dump) ->
        %{
          tone: :alarm,
          headline: "A late pile arrived after the signature. The month does not include it yet.",
          door: %{
            id: "month-door-release-pile",
            label: "Release the pile",
            kind: :click,
            event: "release-dump",
            value: %{"dump-id" => dump.id}
          },
          dump: dump
        }

      dump = find_dump(dumps, "after_filing") ->
        %{
          tone: :calm,
          headline:
            "Documents arrived after this month was filed. A filed return cannot change, so they belong to a later one.",
          door: %{
            id: "month-door-after-filing",
            label: "Bring it into the open month",
            kind: :navigate,
            to: upload_path(facts, facts.open_period)
          },
          dump: dump
        }

      extracting?(dumps) ->
        %{
          tone: :calm,
          headline: "Reading the bills. The month reworks itself when extraction lands.",
          door: nil,
          busy: true
        }

      true ->
        settled_door_and_headline(facts)
    end
  end

  defp door_and_headline(facts), do: settled_door_and_headline(facts)

  defp settled_door_and_headline(%{tracks: %{sales: :absent, purchase: :absent}} = facts) do
    %{
      tone: :calm,
      headline: "Nothing in yet for #{Formatters.period_label(facts.period)}.",
      door: %{
        id: "month-door-bring-documents",
        label: "Bring in documents",
        kind: :navigate,
        to: upload_path(facts, facts.period)
      }
    }
  end

  # 2. The filing gap outranks open work: a signed return cannot change, and
  #    an unfiled one is where a missed filing hides.
  defp settled_door_and_headline(%{tracks: %{purchase: :signed}} = facts),
    do: file_door(facts, :purchase, "GSTR-3B", facts.gstr3b_signoff)

  defp settled_door_and_headline(%{tracks: %{sales: :signed}} = facts),
    do: file_door(facts, :sales, "GSTR-1", facts.r1_signoff)

  # 3. The 2B is published and nobody has fetched it. This outranks every
  #    decision because every decision is behind it: with no 2B side, the
  #    reconciliation matched nothing, so the register's "open" rows are an
  #    artifact of the missing snapshot rather than real disagreements.
  defp settled_door_and_headline(%{tracks: %{purchase: :need_2b}} = facts) do
    %{
      tone: :calm,
      headline: need_2b_headline(facts),
      door: %{
        id: "month-door-bring-2b",
        label: "Bring in the GSTR-2B",
        kind: :navigate,
        to: upload_path(facts, facts.period)
      }
    }
  end

  # 4. Purchase work has its own visible track immediately below this header,
  #    so that track owns the action and the detailed ITC position. The month
  #    header states only the return-level consequence; repeating the amount,
  #    count and button here made the two surfaces chant the same state.
  defp settled_door_and_headline(%{tracks: %{purchase: :open}}) do
    %{
      tone: :calm,
      headline: nil,
      door: nil
    }
  end

  # Everything judgeable is judged; what remains is a document chase. It still
  # belongs to the purchase track rather than becoming a duplicate header door.
  defp settled_door_and_headline(%{tracks: %{purchase: :awaiting_bills}}) do
    %{
      tone: :calm,
      headline: nil,
      door: nil
    }
  end

  defp settled_door_and_headline(%{tracks: %{sales: :open}}) do
    %{
      tone: :calm,
      headline: nil,
      door: nil
    }
  end

  # 5. Worked clean and signable now. The senior's door; the junior has none,
  #    so for them the page falls through to whatever is still missing.
  defp settled_door_and_headline(%{can_sign_off: true, tracks: tracks} = facts)
       when tracks.sales == :clear
       when tracks.purchase == :clear and tracks.sales in [:signed, :filed] do
    %{
      tone: :calm,
      headline: ready_headline(facts),
      door: nil
    }
  end

  # 6. One side worked, the other never arrived.
  defp settled_door_and_headline(%{tracks: %{purchase: :absent}} = facts) do
    %{
      tone: :calm,
      headline: "No purchase bills yet. The 2B reconciliation and the 3B need them.",
      door: %{
        id: "month-door-bring-purchase",
        label: "Bring in the purchase bills",
        kind: :navigate,
        to: upload_path(facts, facts.period)
      }
    }
  end

  defp settled_door_and_headline(%{tracks: %{sales: :absent}} = facts) do
    %{
      tone: :calm,
      headline: settled_money_headline(facts, "No sales bills yet, so the GSTR-1 waits."),
      door: %{
        id: "month-door-bring-sales",
        label: "Bring in the sales bills",
        kind: :navigate,
        to: upload_path(facts, facts.period)
      }
    }
  end

  # 7. The portal has not published the 2B yet, and everything a person could
  #    do has been done. Deliberately doorless: the honest answer to "what is
  #    my move" is "none until the 14th", and inventing a button here is how
  #    the old page ended up sending reviewers at work that cannot be done.
  defp settled_door_and_headline(%{tracks: %{purchase: :awaiting_2b}} = facts) do
    %{tone: :calm, headline: awaiting_2b_headline(facts), door: nil}
  end

  # 8. Both filed.
  defp settled_door_and_headline(%{tracks: %{sales: :filed, purchase: :filed}} = facts) do
    %{
      tone: :calm,
      headline: closed_headline(facts),
      door: nil,
      closed: true
    }
  end

  # 9. Clean, and there is nothing this viewer can press.
  defp settled_door_and_headline(facts) do
    %{
      tone: :calm,
      headline: "Worked and clean. #{money_clause(facts)} Waiting on a senior to sign.",
      door: nil
    }
  end

  # The question that outranks the door. There is no door: three answers of
  # equal weight take its place (`Components.Gst.Month.Precondition`), because a
  # pre-selected answer to a question the product is asking *because it does not
  # know* would be dishonest.
  #
  # Tone follows severity, not volume. Dates outside the period are a question —
  # availing an April credit in June is legal and late bills are ordinary — so
  # the copy states what it saw and never scolds. A duplicate turns the headline
  # red only when the finding graded itself an error, which
  # `Nila.Gst.Intake.Preconditions` does only when the other month is filed: two
  # unfiled drafts holding the same packet is a question about which one is
  # wrong, and red is a claim about consequence we would not be able to back.
  defp question(facts, dump) do
    finding = Dumps.precondition(dump) || %{}

    %{
      tone: question_tone(finding),
      headline: question_headline(finding, facts, subject_noun(dump.kind)),
      door: nil,
      question: %{dump: dump, finding: finding},
      dump: dump
    }
  end

  # Only an explicit "question" stands the alarm down. A finding recorded before
  # severity was derived carries no key, and reading that silence as the calmer
  # grade would quietly downgrade every duplicate already on the board.
  defp question_tone(%{"kind" => "cross_month_duplicate"} = finding),
    do: if(finding["severity"] == "question", do: :calm, else: :alarm)

  defp question_tone(_finding), do: :calm

  # A packet of bills you received and a packet of invoices you raised are not
  # the same noun, and the sentence is the whole surface here. Enumerated for
  # the same reason `Preconditions.check/1` is: a catch-all silently gives a new
  # kind the wrong word instead of failing where someone would notice.
  defp subject_noun("sales"), do: "invoice"
  defp subject_noun("purchase"), do: "bill"
  defp subject_noun("gstr2b"), do: "entry"

  defp question_headline(finding, facts, noun) do
    {sentences, _first?} =
      [&mismatch_sentence/4, &duplicate_sentence/4, &overlap_sentence/4]
      |> Enum.reduce({[], true}, fn build, {acc, first?} ->
        case build.(finding, facts, first?, noun) do
          nil -> {acc, first?}
          sentence -> {[sentence | acc], false}
        end
      end)

    case Enum.reverse(sentences) do
      [] -> "This packet needs a second look before the month is built from it."
      sentences -> Enum.join(sentences, " ")
    end
  end

  defp mismatch_sentence(
         %{"outside_period" => count, "total" => total} = finding,
         facts,
         first?,
         noun
       ) do
    "#{bill_subject(count, total, first?, noun)} #{are(count)} dated #{dated_range(finding)}, " <>
      "not #{Formatters.period_label(facts.period)}."
  end

  defp mismatch_sentence(_finding, _facts, _first?, _noun), do: nil

  defp duplicate_sentence(
         %{"duplicate_of" => %{"period" => period, "count" => count}, "total" => total} = finding,
         _facts,
         first?,
         noun
       ) do
    sentence =
      "#{bill_subject(count, total, first?, noun)} #{are(count)} already in " <>
        "#{Formatters.period_label(period)} — same invoice numbers, same dates."

    case duplicate_grade(finding, period) do
      nil -> sentence
      grade -> sentence <> " " <> grade
    end
  end

  defp duplicate_sentence(_finding, _facts, _first?, _noun), do: nil

  # What the duplicate *costs* is a different sentence from what it is, and the
  # reviewer needs it to know whether they are fixing a filing or picking
  # between two drafts. Neither sentence names a culprit: which of the two
  # copies is the wrong one is precisely what is being asked.
  #
  # A finding recorded before severity was derived gets no grade sentence at
  # all. It keeps the red of the old flat error — conservative, and the tone is
  # a judgement we are allowed to hold — but "Apr 2026 is filed" is a claim
  # about a row nobody read, and inventing it to fill the slot is how a headline
  # stops being checkable.
  defp duplicate_grade(%{"severity" => "question"}, period) do
    "#{Formatters.period_label(period)} is not filed, so nothing has been declared twice yet — " <>
      "but one of the two copies is in the wrong month."
  end

  defp duplicate_grade(%{"severity" => "error"}, period) do
    "#{Formatters.period_label(period)} is filed, so those are already declared."
  end

  defp duplicate_grade(_finding, _period), do: nil

  # What was observed, never a cause the engine cannot know. The same move as
  # the unaccounted-pages ledger one layer down: the engine reporting on the
  # quality of its own output instead of just handing it over.
  defp overlap_sentence(%{"observed" => observed}, _facts, _first?, _noun) do
    books = observed["books"]
    gstr2b = observed["gstr2b"]

    "#{books} purchase #{pluralise(books, "bill")} in and #{gstr2b} " <>
      "2B #{pluralise(gstr2b, "entry", "entries")}, and not one of them matched the other side."
  end

  defp overlap_sentence(_finding, _facts, _first?, _noun), do: nil

  defp bill_subject(count, total, first?, noun) do
    cond do
      count == total and first? -> "All #{total} #{pluralise(total, noun)} in this packet"
      count == total -> "All #{total} of them"
      first? -> "#{count} of this packet's #{total} #{pluralise(total, noun)}"
      true -> "#{count} of them"
    end
  end

  defp are(1), do: "is"
  defp are(_count), do: "are"

  defp dated_range(%{"outside_periods" => [only]}), do: Formatters.period_label(only)

  defp dated_range(%{"outside_periods" => [first | _rest] = periods}) do
    last = List.last(periods)

    if String.slice(first, 0, 4) == String.slice(last, 0, 4),
      do: "#{month_name(first)}–#{Formatters.period_label(last)}",
      else: "#{Formatters.period_label(first)}–#{Formatters.period_label(last)}"
  end

  defp dated_range(_finding), do: "another month"

  defp month_name(period),
    do: period |> Formatters.period_label() |> String.split(" ") |> List.first()

  defp file_door(facts, track, return, signoff) do
    %{
      tone: :calm,
      headline: file_headline(facts, track, return, signoff),
      door: %{
        id: "month-door-file-#{track}",
        label: "File it and record the ARN",
        kind: :anchor,
        to: anchor_for(track)
      },
      filing_track: track
    }
  end

  # Cash payable is the only figure in this whole flow that leaves the client's
  # bank account, and a signed-unfiled 3B is where it is both determined and
  # not yet paid. So it leads. The GSTR-1 carries no payment, and a nil or zero
  # setoff means the number is not established — neither earns a lead.
  defp file_headline(facts, :purchase, return, signoff) do
    case cash_payable(facts) do
      nil -> plain_file_headline(return, signoff)
      cash -> "#{money(cash)} payable. #{plain_file_headline(return, signoff)}"
    end
  end

  defp file_headline(_facts, _track, return, signoff),
    do: plain_file_headline(return, signoff)

  defp plain_file_headline(return, signoff),
    do: "#{return} signed by #{signer(signoff)}. It is not on the portal yet."

  defp cash_payable(%{gstr3b: gstr3b}) when is_map(gstr3b) do
    case get_in(gstr3b, ["setoff_61", "cash_total"]) do
      cash when is_integer(cash) and cash > 0 -> cash
      _ -> nil
    end
  end

  defp cash_payable(_facts), do: nil

  # Both 2B headlines lead with what the month *has* rather than with what it
  # is missing, because the bills being in is the reviewer's own work and it
  # is real. What follows is a date, not a task.
  defp need_2b_headline(facts) do
    "#{bills_clause(facts)} The GSTR-2B has been out since #{gstr2b_date(facts)}. " <>
      "Nothing reconciles until it is in."
  end

  defp awaiting_2b_headline(facts) do
    "#{bills_clause(facts)} The portal publishes the GSTR-2B on #{gstr2b_date(facts)}. " <>
      "Nothing reconciles until then."
  end

  # With no 2B side, nothing can be matched, so the open pot *is* the month's
  # claimable credit. Named for what it is here rather than "riding on N
  # decisions", because there are no decisions yet.
  defp bills_clause(%{stats: %{invoices: count, itc_money_known?: false}}) when count > 0,
    do: "#{count} purchase #{pluralise(count, "bill")} in."

  defp bills_clause(%{stats: %{invoices: count} = stats}) when count > 0,
    do:
      "#{count} purchase #{pluralise(count, "bill")} in, carrying #{money(stats.open_tax_paise)} of ITC."

  defp bills_clause(_facts), do: "The purchase bills are in."

  defp gstr2b_date(facts) do
    facts.period
    |> Calendar.status(facts.today)
    |> Map.fetch!(:gstr2b_due)
    |> Formatters.format_display_date()
  end

  # Same reason as the file door: at a 3B signature the payable is the fact the
  # signer is putting their name to, so it leads rather than trailing the word
  # "Clean". A GSTR-1 signature has no payable, and falls back to the rollup.
  defp ready_headline(facts) do
    cash = signing_3b?(facts) && cash_payable(facts)

    if cash,
      do: "#{money(cash)} payable. Worked and clean.",
      else: "Clean. #{money_clause(facts)}"
  end

  defp signing_3b?(%{tracks: %{sales: sales}}), do: sales in [:signed, :filed]

  defp money_clause(%{gstr3b: gstr3b}) when is_map(gstr3b) do
    itc = heads_total(get_in(gstr3b, ["itc", "net_itc_4c"]))
    cash = get_in(gstr3b, ["setoff_61", "cash_total"])

    if is_integer(cash) do
      "#{money(itc)} ITC, #{money(cash)} payable."
    else
      "#{money(itc)} ITC."
    end
  end

  defp money_clause(%{stats: %{itc_money_known?: false}}), do: ""

  defp money_clause(facts), do: "#{money(facts.stats && facts.stats.matched_tax_paise)} ITC."

  # Gated on the money being recorded, not on the row count. The count survived
  # the freeze on snapshots taken before the tax fields existed and the money did
  # not, so this printed "₹0 ITC matched to 2B" above a register full of matched
  # invoices. When the figure is absent the headline simply drops the clause —
  # the tail still says what the month needs.
  defp settled_money_headline(%{stats: %{matched: matched} = stats}, tail)
       when matched > 0,
       do:
         if(stats.itc_money_known?,
           do: "#{money(stats.matched_tax_paise)} ITC matched to 2B. #{tail}",
           else: tail
         )

  defp settled_money_headline(_facts, tail), do: tail

  defp closed_headline(facts) do
    filed_at = facts.purchase_month && facts.purchase_month.filed_at
    arn = facts.purchase_month && facts.purchase_month.filing_arn

    ["Filed", filed_at && Formatters.format_display_date(to_date(filed_at)), arn && "ARN #{arn}"]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
    |> Kernel.<>(". Month closed.")
  end

  # Every pending track that did not win the door gets one line, so nothing is
  # hidden and nothing competes.
  defp quiet_lines(facts) do
    [track_line(:purchase, facts), track_line(:sales, facts)]
    |> Enum.filter(& &1)
  end

  defp track_line(track, facts) do
    owner = door_owner(facts)

    cond do
      owner == track -> nil
      track == :purchase and facts.tracks.sales == :open -> nil
      true -> line_for(track, facts.tracks[track], facts)
    end
  end

  defp door_owner(facts) do
    case resolve_owner(facts) do
      nil -> nil
      owner -> owner
    end
  end

  # Mirrors the door precedence above, so the quiet lines and the deadline chip
  # always belong to the same track the door does.
  defp resolve_owner(%{tracks: tracks} = facts) do
    cond do
      facts.attention_dumps != [] -> nil
      tracks.purchase == :signed -> :purchase
      tracks.sales == :signed -> :sales
      tracks.purchase == :need_2b -> :purchase
      tracks.purchase == :open -> :purchase
      tracks.sales == :open -> :sales
      signable?(facts, :sales) -> :sales
      signable?(facts, :purchase) -> :purchase
      tracks.purchase == :absent -> :purchase
      tracks.sales == :absent -> :sales
      tracks.purchase == :awaiting_2b -> :purchase
      true -> nil
    end
  end

  defp signable?(%{can_sign_off: false}, _track), do: false
  defp signable?(%{tracks: %{sales: :clear}}, :sales), do: true

  defp signable?(%{tracks: %{purchase: :clear, sales: sales}}, :purchase),
    do: sales in [:signed, :filed]

  defp signable?(_facts, _track), do: false

  defp line_for(:sales, :absent, _facts), do: "Sales bills not in, so the GSTR-1 waits."

  # No count here. The visible GSTR-1 register carries the actionable issue
  # state in each invoice row.
  defp line_for(:sales, :open, %{open_issue_count: n}) when n > 0,
    do: "GSTR-1 drafted, issues still to check."

  defp line_for(:sales, :open, _facts), do: "GSTR-1 drafted, not yet reviewed."
  defp line_for(:sales, :clear, _facts), do: "GSTR-1 worked and clean, waiting on a signature."
  defp line_for(:sales, :signed, _facts), do: "GSTR-1 signed, not yet on the portal."
  defp line_for(:sales, :filed, _facts), do: "GSTR-1 filed."

  defp line_for(:purchase, :absent, _facts),
    do: "Purchase bills not in, so the 2B reconciliation waits."

  defp line_for(:purchase, :awaiting_2b, facts),
    do: "Purchases: the GSTR-2B lands #{gstr2b_date(facts)}."

  defp line_for(:purchase, :need_2b, _facts), do: "Purchases: the GSTR-2B is not in yet."

  defp line_for(:purchase, :open, %{stats: %{need_decision: n}}) when n > 0,
    do: "Purchases: #{n} #{pluralise(n, "decision")} waiting."

  defp line_for(:purchase, :awaiting_bills, %{stats: %{awaiting_bills: n}}) when n > 0,
    do: "Purchases: #{n} #{pluralise(n, "bill")} in the 2B but not supplied."

  defp line_for(:purchase, :open, _facts), do: "Purchases not yet reconciled."
  defp line_for(:purchase, :clear, _facts), do: "Purchases clear, waiting on a signature."
  defp line_for(:purchase, :signed, _facts), do: "GSTR-3B signed, not yet on the portal."
  defp line_for(:purchase, :filed, _facts), do: "GSTR-3B filed."
  defp line_for(_track, _status, _facts), do: nil

  # Retained as the state table's primary clock for callers that need one track
  # to win. The masthead follows the same working sequence: while GSTR-1 is open,
  # its clock is the only one that can change the reviewer's next move.
  defp put_deadline(verdict, facts) do
    track = resolve_owner(facts) || fallback_track(facts)
    deadline = track && WorkQueue.track_deadline(facts.period, facts.today, track)

    Map.put(verdict, :deadline, deadline)
  end

  defp put_deadlines(verdict, facts) do
    deadlines =
      for {track, status} <- [sales: facts.tracks.sales, purchase: facts.tracks.purchase],
          not (facts.tracks.sales == :open and track == :purchase),
          status != :filed do
        {track, WorkQueue.track_deadline(facts.period, facts.today, track)}
      end

    Map.put(verdict, :deadlines, deadlines)
  end

  defp fallback_track(%{tracks: %{sales: :filed, purchase: :filed}}), do: nil
  defp fallback_track(%{tracks: %{sales: sales}}) when sales != :filed, do: :sales
  defp fallback_track(_facts), do: :purchase

  defp find_dump(dumps, status), do: Enum.find(dumps, &(&1.status == status))
  defp extracting?(dumps), do: Enum.any?(dumps, &(&1.status in ~w(received extracting)))

  defp releasable?(%{r1_signoff: signoff}, %{kind: "sales"}), do: is_nil(signoff)
  defp releasable?(%{gstr3b_signoff: signoff}, _dump), do: is_nil(signoff)

  defp anchor_for(:sales), do: "#month-exit-gstr1"
  defp anchor_for(:purchase), do: "#month-exit-gstr3b"
  defp source_anchor(kind) when kind in ~w(sales filed_gstr1), do: "#month-sales-sources"
  defp source_anchor(kind) when kind in ~w(purchase gstr2b), do: "#month-purchase-sources"

  defp upload_path(facts, period),
    do: ~p"/gst/upload?client_id=#{facts.client.id}&period=#{period}"

  defp signer(nil), do: "a senior"
  defp signer(signoff), do: (signoff.signed_by && signoff.signed_by.name) || "a senior"

  defp heads_total(nil), do: 0

  defp heads_total(heads),
    do: (heads["igst"] || 0) + (heads["cgst"] || 0) + (heads["sgst"] || 0)

  defp money(nil), do: "₹0"
  defp money(paise), do: Formatters.format_money(paise, prefix: "₹")

  defp to_date(%Date{} = date), do: date
  defp to_date(%DateTime{} = datetime), do: DateTime.to_date(datetime)
  defp to_date(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_date(datetime)
  defp to_date(_other), do: nil

  defp pluralise(count, word, plural \\ nil)
  defp pluralise(1, word, _plural), do: word
  defp pluralise(_count, word, nil), do: word <> "s"
  defp pluralise(_count, _word, plural), do: plural

  @doc "A compact identity and status header for the month workbench."
  attr :verdict, :map, required: true
  attr :client, :map, required: true
  attr :period, :string, required: true
  attr :client_switcher_open?, :boolean, default: false

  def verdict(assigns) do
    ~H"""
    <section id="month-verdict" class="border-base-300 pb-section border-b">
      <div class="gap-block flex flex-col lg:flex-row lg:items-start lg:justify-between">
        <div class="space-y-related min-w-0">
          <ClientSwitcher.trigger
            client={@client}
            period={@period}
            open?={@client_switcher_open?}
          />
          <p
            :if={@verdict.headline}
            id="month-headline"
            class={[
              "text-body max-w-3xl font-medium",
              (@verdict.tone == :alarm && "text-error") || "text-base-content"
            ]}
          >
            {@verdict.headline}
          </p>
          <div
            :if={@verdict.deadlines != []}
            id="month-deadlines"
            class="text-body text-ink-muted flex flex-wrap items-center gap-x-4 gap-y-1"
          >
            <span
              :for={{track, deadline} <- @verdict.deadlines}
              id={"month-deadline-#{track}"}
              class={deadline_class(deadline)}
            >
              {deadline.return} · {deadline_label(deadline)}
            </span>
          </div>
          <div
            :if={@verdict.quiet != []}
            class="text-body text-ink-muted flex flex-wrap items-center gap-x-4 gap-y-1"
          >
            <span :for={line <- @verdict.quiet} id={"month-quiet-#{line_id(line)}"}>{line}</span>
          </div>
          <p
            :if={Map.get(@verdict, :busy)}
            id="month-busy"
            class="text-body text-ink-muted flex items-center gap-2"
          >
            <span class="text-moon"><.spinner label="Updating month" /></span>
            This page updates itself as each pile lands.
          </p>
        </div>

        <div :if={@verdict.door} class="shrink-0">
          <.door door={@verdict.door} />
        </div>
      </div>
    </section>
    """
  end

  attr :door, :map, required: true

  defp door(%{door: %{kind: :navigate}} = assigns) do
    ~H"""
    <.button id={@door.id} navigate={@door.to} variant="outline" size="sm">
      {@door.label} <.icon name="hero-arrow-right-mini" class="size-4" />
    </.button>
    """
  end

  defp door(%{door: %{kind: :patch}} = assigns) do
    ~H"""
    <.button id={@door.id} patch={@door.to} variant="outline" size="sm">
      {@door.label} <.icon name="hero-arrow-right-mini" class="size-4" />
    </.button>
    """
  end

  defp door(%{door: %{kind: :anchor}} = assigns) do
    ~H"""
    <.button
      id={@door.id}
      href={@door.to}
      variant="outline"
      size="sm"
    >
      {@door.label} <.icon name="hero-arrow-right-mini" class="size-4" />
    </.button>
    """
  end

  defp door(%{door: %{kind: :click}} = assigns) do
    ~H"""
    <.button
      id={@door.id}
      variant="outline"
      size="sm"
      phx-click={@door.event}
      {door_values(@door)}
    >
      {@door.label} <.icon name="hero-arrow-right-mini" class="size-4" />
    </.button>
    """
  end

  defp door_values(%{value: value}) when is_map(value) do
    Map.new(value, fn {key, val} -> {:"phx-value-#{key}", val} end)
  end

  defp door_values(_door), do: %{}

  defp line_id(line) do
    line |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.slice(0, 24)
  end

  defp deadline_class(%{days_left: days}) when days < 0, do: "text-error font-medium"
  defp deadline_class(%{days_left: days}) when days <= 5, do: "text-warning font-medium"
  defp deadline_class(_deadline), do: "text-ink-muted"

  defp deadline_label(%{days_left: days, due: due}) when days < 0,
    do: "due #{Formatters.format_display_date(due)} · #{-days} days overdue"

  defp deadline_label(%{days_left: 0, due: due}),
    do: "due today, #{Formatters.format_display_date(due)}"

  defp deadline_label(%{days_left: days, due: due}),
    do: "due #{Formatters.format_display_date(due)} · #{days}d left"
end
