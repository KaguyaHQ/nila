defmodule NilaWeb.Components.Gst.Month.Verdict do
  use NilaWeb, :html

  @moduledoc """
  The month's verdict and its single door.

  The page this replaced rendered the data model: six conditional CTAs, a
  four-dot spine, a deadline chip, and 23 register rows all at the same visual
  volume, and the owner of the product could not find the primary action. The
  rule here is the opposite one. **At any moment the month is in exactly one
  state, and each state has exactly one next action.** Everything else on the
  page is folded context.

  The month is a pair (`WorkQueue.track_states/1`), so this module owns the
  precedence that turns a pair into one door:

    1. An interrupted pile (failed / held / arrived-after-filing) wins, because
       decisions taken on half the documents are worth nothing.
    2. A signed-but-unfiled return wins next. Filing is the step nobody may
       miss, and a signed return cannot change anyway.
    3. Otherwise the highest-precedence track with live work, purchases before
       sales: the 2B window is the harder deadline, the rupee exposure is
       larger, and purchase decisions are clearable *now* by the person on the
       page, while missing sales bills are waiting on someone else.
    4. Whatever a track's role cannot act on is not live work for that viewer
       (a junior never gets a sign door).

  Every other pending track becomes one quiet line, never a second button.
  """

  alias Nila.Formatters
  alias Nila.Gst.WorkQueue

  @doc """
  Resolves the facts of a month into `%{headline, tone, quiet, door, deadline}`.

  Kept separate from the markup so the state table is testable as data rather
  than by scraping HTML.
  """
  def resolve(facts) do
    facts
    |> door_and_headline()
    |> Map.put(:quiet, quiet_lines(facts))
    |> put_deadline(facts)
  end

  # 1. Interrupted piles.
  defp door_and_headline(%{attention_dumps: dumps} = facts) when dumps != [] do
    cond do
      dump = find_dump(dumps, "failed") ->
        %{
          tone: :alarm,
          headline: "A pile failed to extract. The month is working off partial documents.",
          door: %{
            id: "month-door-failed-pile",
            label: "See what happened",
            kind: :anchor,
            to: "#month-paper-trail",
            open: "month-paper-trail"
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

  # 3. Live work, purchases first. A track that is merely *absent* is not live
  #    work for the person on the page (it is a chase, and it is somebody
  #    else's move), so it must not outrank a signature that is ready now.
  #    Each return has its own deadline; the GSTR-1 does not wait on purchase
  #    bills it will never contain.
  defp settled_door_and_headline(%{tracks: %{purchase: :open}} = facts) do
    count = facts.stats.need_decision

    %{
      tone: :calm,
      headline: decisions_headline(facts, count),
      door: %{
        id: "month-door-decisions",
        label: "Work the #{count} #{pluralise(count, "decision")}",
        kind: :navigate,
        to: ~p"/gst/#{facts.client.id}/#{facts.period}/exceptions"
      }
    }
  end

  defp settled_door_and_headline(%{tracks: %{sales: :open}} = facts) do
    count = facts.open_issue_count

    if count > 0 do
      %{
        tone: :calm,
        headline: sales_issues_headline(facts, count),
        door: sales_issue_door(facts, count)
      }
    else
      %{
        tone: :calm,
        headline: "GSTR-1 drafted and clean. Mark it reviewed to pass it to a senior.",
        door:
          facts.reviewable &&
            %{
              id: "month-door-mark-reviewed",
              label: "Mark the GSTR-1 reviewed",
              kind: :click,
              event: "mark_reviewed",
              value: %{}
            }
      }
    end
  end

  # 4. Worked clean and signable now. The senior's door; the junior has none,
  #    so for them the page falls through to whatever is still missing.
  defp settled_door_and_headline(%{can_sign_off: true, tracks: tracks} = facts)
       when tracks.sales == :clear
       when tracks.purchase == :clear and tracks.sales in [:signed, :filed] do
    {event, label, id} = sign_target(facts)

    %{
      tone: :calm,
      headline: ready_headline(facts),
      door: %{id: id, label: label, kind: :click, event: event, value: %{}}
    }
  end

  # 5. One side worked, the other never arrived.
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

  # 6. Both filed.
  defp settled_door_and_headline(%{tracks: %{sales: :filed, purchase: :filed}} = facts) do
    %{
      tone: :calm,
      headline: closed_headline(facts),
      door: nil,
      closed: true
    }
  end

  # 7. Clean, and there is nothing this viewer can press.
  defp settled_door_and_headline(facts) do
    %{
      tone: :calm,
      headline: "Worked and clean. #{money_clause(facts)} Waiting on a senior to sign.",
      door: nil
    }
  end

  defp file_door(_facts, track, return, signoff) do
    %{
      tone: :calm,
      headline: "#{return} signed by #{signer(signoff)}. It is not on the portal yet.",
      door: %{
        id: "month-door-file-#{track}",
        label: "File it and record the ARN",
        kind: :anchor,
        to: anchor_for(track),
        open: "month-exit"
      },
      filing_track: track
    }
  end

  defp sign_target(%{tracks: %{sales: sales}}) when sales in [:signed, :filed],
    do: {"3b-sign-off", "Sign the GSTR-3B", "month-door-sign-3b"}

  defp sign_target(%{tracks: %{sales: :clear}}),
    do: {"r1-sign-off", "Sign the GSTR-1", "month-door-sign-r1"}

  # Headlines lead with rupees whenever rupees exist. A screen without a money
  # rollup is not a position, it is homework.
  defp decisions_headline(facts, count) do
    stats = facts.stats
    riding = money(stats.open_tax_paise)
    clean = money(stats.matched_tax_paise)

    prefix =
      case facts.tracks.sales do
        :filed -> "GSTR-1 filed."
        _ -> "#{clean} ITC clean."
      end

    "#{prefix} #{riding} riding on #{count} #{pluralise(count, "decision")}."
  end

  # A door has to land on the control that does the work. An invoice-level
  # issue's confirm button lives in that invoice's modal and nowhere else — the
  # table only shows an "n open" cell — so the door opens the modal directly.
  # An anchor would be a no-op here anyway whenever the sales section is
  # already unfolded, which is exactly when the sales track owns the door.
  # Month-level issues do render as cards inside the section, so those keep the
  # anchor and the unfold.
  defp sales_issue_door(%{open_issue_invoice: inum}, count) when is_binary(inum) do
    %{
      id: "month-door-sales-issues",
      label: "Check the #{count} #{pluralise(count, "issue")}",
      kind: :click,
      event: "select-invoice",
      value: %{"inum" => inum}
    }
  end

  defp sales_issue_door(_facts, count) do
    %{
      id: "month-door-sales-issues",
      label: "Check the #{count} #{pluralise(count, "issue")}",
      kind: :anchor,
      to: "#month-sales",
      open: "month-sales"
    }
  end

  defp sales_issues_headline(%{tracks: %{purchase: :absent}}, count),
    do: "GSTR-1 drafted. #{count} #{pluralise(count, "issue")} to check."

  defp sales_issues_headline(facts, count),
    do:
      "Purchases clear, #{money(facts.stats.matched_tax_paise)} ITC. " <>
        "GSTR-1 has #{count} #{pluralise(count, "issue")} to check."

  defp ready_headline(facts) do
    "Clean. #{money_clause(facts)}"
  end

  defp money_clause(%{gstr3b: gstr3b}) when is_map(gstr3b) do
    itc = heads_total(get_in(gstr3b, ["itc", "net_itc_4c"]))
    cash = get_in(gstr3b, ["setoff_61", "cash_total"])

    if is_integer(cash) do
      "#{money(itc)} ITC, #{money(cash)} payable."
    else
      "#{money(itc)} ITC."
    end
  end

  defp money_clause(facts), do: "#{money(facts.stats && facts.stats.matched_tax_paise)} ITC."

  defp settled_money_headline(%{stats: %{matched: matched} = stats}, tail) when matched > 0,
    do: "#{money(stats.matched_tax_paise)} ITC matched to 2B. #{tail}"

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
    if owner == track, do: nil, else: line_for(track, facts.tracks[track], facts)
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
      tracks.purchase == :open -> :purchase
      tracks.sales == :open -> :sales
      signable?(facts, :sales) -> :sales
      signable?(facts, :purchase) -> :purchase
      tracks.purchase == :absent -> :purchase
      tracks.sales == :absent -> :sales
      true -> nil
    end
  end

  defp signable?(%{can_sign_off: false}, _track), do: false
  defp signable?(%{tracks: %{sales: :clear}}, :sales), do: true

  defp signable?(%{tracks: %{purchase: :clear, sales: sales}}, :purchase),
    do: sales in [:signed, :filed]

  defp signable?(_facts, _track), do: false

  defp line_for(:sales, :absent, _facts), do: "Sales bills not in, so the GSTR-1 waits."

  defp line_for(:sales, :open, %{open_issue_count: n}) when n > 0,
    do: "GSTR-1: #{n} #{pluralise(n, "issue")} waiting."

  defp line_for(:sales, :open, _facts), do: "GSTR-1 drafted, not yet reviewed."
  defp line_for(:sales, :clear, _facts), do: "GSTR-1 worked and clean, waiting on a signature."
  defp line_for(:sales, :signed, _facts), do: "GSTR-1 signed, not yet on the portal."
  defp line_for(:sales, :filed, _facts), do: "GSTR-1 filed."

  defp line_for(:purchase, :absent, _facts),
    do: "Purchase bills not in, so the 2B reconciliation waits."

  defp line_for(:purchase, :open, %{stats: %{need_decision: n}}) when n > 0,
    do: "Purchases: #{n} #{pluralise(n, "decision")} waiting."

  defp line_for(:purchase, :open, _facts), do: "Purchases not yet reconciled."
  defp line_for(:purchase, :clear, _facts), do: "Purchases clear, waiting on a signature."
  defp line_for(:purchase, :signed, _facts), do: "GSTR-3B signed, not yet on the portal."
  defp line_for(:purchase, :filed, _facts), do: "GSTR-3B filed."
  defp line_for(_track, _status, _facts), do: nil

  # The chip follows whichever track owns the door, because a reviewer working
  # 3B decisions does not need the GSTR-1 clock. A filed return never owns the
  # door, so a closed month shows no clock at all; an unfiled one keeps its
  # alarm however old, because late is late.
  defp put_deadline(verdict, facts) do
    track = resolve_owner(facts) || fallback_track(facts)
    deadline = track && WorkQueue.track_deadline(facts.period, facts.today, track)

    Map.put(verdict, :deadline, deadline)
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

  defp pluralise(1, word), do: word
  defp pluralise(_count, word), do: word <> "s"

  @doc """
  The verdict block: what the month is, what it is worth, and the one thing to
  do about it. The only display-size text and the only saturated control on the
  page both live here.
  """
  attr :verdict, :map, required: true
  attr :client, :map, required: true
  attr :period, :string, required: true

  def verdict(assigns) do
    ~H"""
    <section id="month-verdict" class="space-y-5">
      <div class="space-y-2">
        <p class="text-eyebrow text-moon font-semibold uppercase">Client month</p>
        <h1 class="font-display text-base-content text-h2 font-normal">
          {@client.name} · {Formatters.period_label(@period)}
        </h1>
        <p
          id="month-headline"
          class={[
            "text-lead max-w-2xl",
            (@verdict.tone == :alarm && "text-error") || "text-base-content"
          ]}
        >
          {@verdict.headline}
        </p>
      </div>

      <div
        :if={@verdict.quiet != [] or @verdict.deadline}
        class="text-base-content/55 text-small flex flex-wrap items-center gap-x-4 gap-y-1"
      >
        <span :for={line <- @verdict.quiet} id={"month-quiet-#{line_id(line)}"}>{line}</span>
        <span :if={@verdict.deadline} id="month-deadline" class={deadline_class(@verdict.deadline)}>
          {@verdict.deadline.return} · {deadline_label(@verdict.deadline)}
        </span>
      </div>

      <div :if={@verdict.door} class="pt-1">
        <.door door={@verdict.door} />
      </div>

      <p
        :if={Map.get(@verdict, :busy)}
        id="month-busy"
        class="text-base-content/55 text-small flex items-center gap-2"
      >
        <span class="loading loading-sm loading-spinner text-moon"></span>
        This page updates itself as each pile lands.
      </p>
    </section>
    """
  end

  attr :door, :map, required: true

  defp door(%{door: %{kind: :navigate}} = assigns) do
    ~H"""
    <.button id={@door.id} navigate={@door.to} variant="primary" size="lg" class="gap-2">
      {@door.label} <.icon name="hero-arrow-right-mini" class="size-4" />
    </.button>
    """
  end

  defp door(%{door: %{kind: :anchor}} = assigns) do
    ~H"""
    <.button
      id={@door.id}
      href={@door.to}
      variant="primary"
      size="lg"
      class="gap-2"
      phx-click={open_details(@door)}
    >
      {@door.label} <.icon name="hero-arrow-right-mini" class="size-4" />
    </.button>
    """
  end

  defp door(%{door: %{kind: :click}} = assigns) do
    ~H"""
    <.button
      id={@door.id}
      variant="primary"
      size="lg"
      class="gap-2"
      phx-click={@door.event}
      {door_values(@door)}
    >
      {@door.label} <.icon name="hero-arrow-right-mini" class="size-4" />
    </.button>
    """
  end

  # An anchor door whose target is folded has to unfold it, or the button
  # scrolls to a closed disclosure and the reviewer sees nothing happen.
  defp open_details(%{open: id}), do: JS.set_attribute({"open", "true"}, to: "##{id}")
  defp open_details(_door), do: %JS{}

  defp door_values(%{value: value}) when is_map(value) do
    Map.new(value, fn {key, val} -> {:"phx-value-#{key}", val} end)
  end

  defp door_values(_door), do: %{}

  defp line_id(line) do
    line |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.slice(0, 24)
  end

  defp deadline_class(%{days_left: days}) when days < 0, do: "text-error font-medium"
  defp deadline_class(%{days_left: days}) when days <= 5, do: "text-warning font-medium"
  defp deadline_class(_deadline), do: "text-base-content/55"

  defp deadline_label(%{days_left: days, due: due}) when days < -30,
    do: "overdue since #{Formatters.format_display_date(due)}"

  defp deadline_label(%{days_left: days}) when days < 0, do: "#{-days}d overdue"
  defp deadline_label(%{days_left: 0}), do: "due today"
  defp deadline_label(%{days_left: days}), do: "#{days}d left"
end
