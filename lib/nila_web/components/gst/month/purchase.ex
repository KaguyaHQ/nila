defmodule NilaWeb.Components.Gst.Month.Purchase do
  use NilaWeb, :html

  @moduledoc """
  Purchase reconciliation evidence. Every register row patches into the
  route-backed purchase review surface without unmounting the month.

  The section states its own ITC position before the evidence that determines
  it. The assembled return follows that evidence and sits directly beside the
  action that signs it, matching the sales track's filing-summary placement.
  The month-wide verdict band can only ever speak for one track, so a purchase
  position that lives only there disappears whenever sales wins the band.
  """

  alias Nila.Gst.Purchase.Register
  alias NilaWeb.Components.Gst.Exceptions.Itc

  attr :purchase_month, :any, default: nil
  attr :deadline, :any, default: nil
  attr :stats, :any, default: nil
  attr :document_flags, :list, default: []
  attr :rows, :list, required: true
  attr :client, :map, required: true
  attr :period, :string, required: true
  attr :gstr3b_signoff, :any, default: nil
  attr :source_files, :integer, default: 0
  attr :pages_read, :integer, default: nil
  attr :itc, :any, default: nil
  attr :case_lines, :list, default: []
  slot :source
  slot :assembled
  slot :actions

  @doc "The complete purchase register, always visible as month evidence."
  def register(assigns) do
    assigns =
      assigns
      |> assign(:verdict, verdict_state(assigns))
      |> assign(:carried_itc, carried_itc(assigns.case_lines, assigns.period))

    ~H"""
    <section :if={@purchase_month} id="month-register" class="space-y-section">
      <header id="gstr3b-verdict" class="border-base-300 pb-block border-b">
        <div class="flex flex-wrap items-start justify-between gap-4">
          <div class="min-w-0 space-y-1">
            <h2 class="text-base-content text-h4 font-semibold">Purchase reconciliation</h2>
            <p id="gstr3b-itc-position" class="text-body text-ink-muted">
              {@verdict.copy}
            </p>
          </div>
          <.button
            :if={@stats.need_decision > 0}
            id="gstr3b-review-required"
            patch={~p"/gst/#{@client.id}/#{@period}/review/purchase?scope=needs_you"}
            variant="primary"
            size="sm"
          >
            {review_label(@stats.need_decision)}
          </.button>
          <%!-- Nothing left to judge, so the action is the chase. --%>
          <.button
            :if={@stats.need_decision == 0 and @stats.awaiting_bills > 0}
            id="gstr3b-request-bills"
            patch={~p"/gst/#{@client.id}/#{@period}/review/purchase?scope=needs_you"}
            variant="primary"
            size="sm"
          >
            Request {@stats.awaiting_bills} missing {plural(@stats.awaiting_bills, "document")}
          </.button>
        </div>
      </header>

      <section id="gstr3b-completeness" class="space-y-block">
        <h3 class="text-base-content text-body font-semibold">Completeness</h3>

        <%!-- "0 files received" beside "12 invoices extracted" is an impossible
              pair, and printing it flat as fact teaches a reviewer to distrust
              the whole block. A count that cannot be true is a count we do not
              have — a month reconciled from an import or a backfill never had a
              file pass through intake. Say that instead of asserting zero. --%>
        <dl class="border-base-300 gap-block py-block grid border-y sm:grid-cols-2 lg:grid-cols-4">
          <.control_stat
            label="Source files received"
            value={@source_files}
            unknown={@source_files == 0 and @stats.invoices > 0}
            unknown_note="not recorded for this month"
          />
          <.control_stat :if={@pages_read} label="Document pages read" value={@pages_read} />
          <.control_stat label="Purchase documents extracted" value={@stats.invoices} />
          <.control_stat label="Pages with no document" value={length(@document_flags)} />
        </dl>
      </section>

      <section id="gstr3b-reconciliation" class="space-y-block">
        <h3 class="text-base-content text-body font-semibold">ITC reconciliation</h3>

        <%!-- The same bridge the workbench draws. Two screens describing one
              month's ITC in two vocabularies is how a reviewer ends up unsure
              whether the numbers disagree or the words do. --%>
        <Itc.itc_bridge :if={@itc} itc={@itc} stats={@stats} id="gstr3b-itc-bridge" />

        <%!-- Nine tiles asked the reader to work out which counts overlapped and
              which were subsets. These three rows partition the register: every
              row is in exactly one, they carry the money as well as the count,
              and each names the move it is waiting on. --%>
        <.data_table
          id="gstr3b-reconciliation-matrix"
          rows={reconciliation_rows(@stats)}
          row_id={&"gstr3b-recon-#{&1.key}"}
          min_width="min-w-[560px]"
          dense
        >
          <:col :let={row} label="Position">
            <span class="text-base-content font-medium">{row.label}</span>
            <span class="text-ink-subtle text-meta block">{row.note}</span>
          </:col>
          <:col :let={row} label="Bills" align="right">{row.count}</:col>
          <%!-- The counts came through the freeze and the money did not, so this
                column is the one that has to decline. Printing ₹0 down a table
                whose neighbouring column counts real bills is the same false
                confidence as the tiles above, spread over three rows. --%>
          <:col :let={row} label="Face tax" align="right">
            <span :if={@stats.itc_money_known?}>{format_money(row.tax_paise, prefix: "₹")}</span>
            <span :if={not @stats.itc_money_known?} class="text-ink-subtle">—</span>
          </:col>
          <:col :let={row} label="Next move">
            <span class="text-ink-muted">{row.next_move}</span>
          </:col>
        </.data_table>

        <section :if={@carried_itc != []} id="gstr3b-carried-itc" class="space-y-related">
          <div>
            <h4 class="text-base-content text-ui font-semibold">Prior-period ITC</h4>
            <p class="text-ink-subtle text-meta">
              Earlier invoices whose credit is still moving through evidence or this period's claim.
            </p>
          </div>
          <div class="border-base-300 divide-base-300 rounded-box divide-y border">
            <div
              :for={line <- @carried_itc}
              id={"gstr3b-carried-itc-#{line.case_id}"}
              class="gap-related grid items-center px-4 py-3 sm:grid-cols-[7rem_minmax(0,1fr)_auto]"
            >
              <div class="text-ink-subtle text-meta font-medium uppercase">
                {carried_origin(line)}
              </div>
              <div class="min-w-0">
                <div class="text-base-content text-ui truncate font-medium">
                  {line.invoice_number || "—"} · {line.vendor}
                </div>
                <div class="text-ink-subtle text-meta">{carried_status(line)}</div>
              </div>
              <div class="text-base-content text-ui font-mono">
                {format_money(line.tax_paise, prefix: "₹")}
              </div>
            </div>
          </div>
        </section>

        <div :if={@document_flags != []} id="gst-document-flags" class="space-y-related">
          <div
            :for={{flag, index} <- Enum.with_index(@document_flags)}
            id={"gst-document-flag-#{index}"}
            class="border-base-300 rounded-box flex flex-wrap items-center gap-3 border px-4 py-3"
          >
            <span class="text-ink-subtle text-meta font-medium">{issue_label(flag["code"])}</span>
            <span class="text-body text-ink-muted min-w-0 flex-1">{flag["reason"]}</span>
          </div>
        </div>
      </section>

      <section class="space-y-block">
        <h3 class="text-base-content text-body font-semibold">Source documents</h3>
        {render_slot(@source)}
      </section>

      <div class="space-y-block">
        <div class="gap-related flex flex-wrap items-end justify-between">
          <h3 class="text-base-content text-body font-semibold">Purchase register</h3>
          <%!-- "Complete register" was read as "the purchase register is
                complete" — a claim this page cannot make while bills sit in 2B
                unsupplied. Nor can it call every row an extracted invoice: a
                2B-only row is a bill nobody sent, so a month with no purchase
                documents at all read "0 extracted" beside 8 rows of them. --%>
          <p class="text-ink-muted text-ui">
            {@stats.invoices} purchase {plural(@stats.invoices, "document")} extracted{if @stats.gstr2b_only >
                                                                                            0,
                                                                                          do:
                                                                                            " · #{@stats.gstr2b_only} from 2B only"}
          </p>
        </div>

        <.data_table
          id="gst-register"
          rows={@rows}
          row_id={fn row -> row["dom_id"] end}
          row_click={&row_click(&1, @client, @period)}
          row_class={&row_accent/1}
          min_width="min-w-[880px]"
        >
          <:col :let={row} label="Document no">
            <div class="flex items-center gap-2">
              <.icon
                :if={Register.open_row?(row)}
                name="hero-exclamation-triangle-mini"
                class="text-warning size-4 shrink-0"
              />
              <span class="font-medium">{row["invoice_number"] || "—"}</span>
              <span :if={row["document_type"] != "invoice"} class="text-ink-subtle text-meta">
                {document_abbreviation(row)}
              </span>
            </div>
          </:col>
          <:col :let={row} label="Vendor">{row["vendor_name"]}</:col>
          <:col :let={row} label="Taxable" align="right">
            {format_money(row["taxable_paise"], prefix: "₹")}
          </:col>
          <:col :let={row} label="ITC effect" align="right">
            <span class={row["itc_effect_paise"] < 0 && "text-error"}>
              {signed_money(row["itc_effect_paise"])}
            </span>
          </:col>
          <%!-- The label already tells the truth for a flagged match (see
                `Register.bucket_label/2`); the variant has to stop painting it
                green to match. --%>
          <:col :let={row} label="2B status">
            <.badge variant={status_variant(row)}>{row["bucket_label"]}</.badge>
          </:col>
          <%!-- The note still speaks for any flagged row: an invalid GSTIN on a
                matched bill is worth reading. What the flag no longer buys is
                the ⚠ and the accent, which belong to rows that need a decision. --%>
          <%!-- The verdict names what is wrong; the row also carries the move it
                waits on, and the register showed only the first. A reviewer
                deciding whether to leave for the queue was reading the problem
                with the answer one screen away. Both hang off `annotated_row?`,
                which already goes quiet once a row is decided — a follow-up
                printed under a settled bill reads as an instruction to redo it. --%>
          <:col :let={row} label="Note" class="max-w-sm">
            <span :if={Register.annotated_row?(row)} class="text-base-content block truncate">
              {row["verdict"]}
            </span>
            <span
              :if={Register.annotated_row?(row) and row["next_action"]}
              class="text-ink-subtle text-meta mt-0.5 block truncate"
            >
              {row["next_action"]}
            </span>
          </:col>
          <:empty>The register is empty for this month.</:empty>
        </.data_table>
      </div>

      {render_slot(@assembled)}
      {render_slot(@actions)}
    </section>
    """
  end

  defp carried_itc(case_lines, period) do
    case_lines
    |> Enum.filter(fn line ->
      periods = line.books_periods ++ line.gstr2b_periods

      Enum.any?(periods, &(&1 < period)) and
        line.settlement_state not in ~w(claimed excluded)
    end)
    |> Enum.sort_by(&{carried_origin(&1), &1.invoice_number || "", &1.case_id})
  end

  defp carried_origin(line) do
    (line.books_periods ++ line.gstr2b_periods)
    |> Enum.min(fn -> nil end)
    |> case do
      nil -> "Earlier"
      period -> Nila.Formatters.period_label(period)
    end
  end

  defp carried_status(%{evidence_state: "awaiting_2b"}), do: "Awaiting the vendor's 2B"
  defp carried_status(%{evidence_state: "awaiting_document"}), do: "Awaiting the tax invoice"

  defp carried_status(%{settlement_state: "available", current_gstr2b?: true}),
    do: "Ready to claim in this period"

  defp carried_status(%{settlement_state: "available"}),
    do: "Evidence complete; later-claim treatment needs review"

  defp carried_status(%{settlement_state: "reserved"}), do: "Reserved by this period's sign-off"
  defp carried_status(_), do: "Carried forward"

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :unknown, :boolean, default: false
  attr :unknown_note, :string, default: nil

  defp control_stat(assigns) do
    ~H"""
    <div>
      <dt class="text-ink-subtle text-label font-semibold uppercase">{@label}</dt>
      <dd
        :if={not @unknown}
        class="text-base-content text-body mt-1 font-medium tabular-nums"
      >
        {@value}
      </dd>
      <dd :if={@unknown} class="text-body text-ink-subtle mt-1 font-medium">
        — <span class="text-meta">{@unknown_note}</span>
      </dd>
    </div>
    """
  end

  # The register's three terminal positions, each with its count, its money and
  # the move it waits on. `matched + open` does not close the month on its own —
  # audited-accepted rows sit in neither — so settled is used as open's exact
  # complement and the three rows sum to the register.
  defp reconciliation_rows(stats) do
    decisions_tax =
      if stats.open_money_split_known?,
        do: stats.decision_tax_paise + stats.value_dispute_tax_paise,
        else: stats.open_tax_paise - stats.awaiting_bills_tax_paise

    [
      %{
        key: "settled",
        label: "Document and 2B agree",
        note: "Matched to the portal, or ruled on and closed",
        count: stats.rows - stats.open,
        tax_paise: stats.settled_tax_paise,
        next_move: "Nothing"
      },
      %{
        key: "decisions",
        label: "Document supplied, not settled against 2B",
        note: "Absent from the 2B, ambiguous, or disagreeing on amount",
        count: stats.open - stats.awaiting_bills,
        tax_paise: decisions_tax,
        next_move:
          if(stats.open - stats.awaiting_bills > 0,
            do: "Yours to decide",
            else: "Nothing"
          )
      },
      %{
        key: "awaiting",
        label: "In 2B, document not supplied",
        note: "The portal reported a supply or adjustment nobody sent us a document for",
        count: stats.awaiting_bills,
        tax_paise: stats.awaiting_bills_tax_paise,
        next_move: if(stats.awaiting_bills > 0, do: "Ask the client", else: "Nothing")
      }
    ]
  end

  # The component is invoked for every month and hides itself when there is no
  # purchase track, but assigns are prepared before HEEx applies that `:if`.
  defp verdict_state(%{stats: nil}), do: %{copy: nil}

  defp verdict_state(%{
         gstr3b_signoff: %{},
         purchase_month: %{filed_at: filed_at},
         stats: stats
       })
       when not is_nil(filed_at),
       do: %{copy: lifecycle_copy(stats, :filed)}

  defp verdict_state(%{gstr3b_signoff: %{}, stats: stats}),
    do: %{copy: lifecycle_copy(stats, :signed)}

  defp verdict_state(%{stats: %{need_decision: count} = stats}) when count > 0,
    do: %{copy: decision_copy(stats, count)}

  # Reconciled as far as the supplied documents allow. Nobody on this page can
  # move it: the portal reported supplies whose bills were never sent, so the
  # next step is a request, not a judgement.
  defp verdict_state(%{stats: %{awaiting_bills: count} = stats}) when count > 0,
    do: %{copy: awaiting_bills_copy(stats, count)}

  defp verdict_state(%{stats: stats}), do: %{copy: reconciled_copy(stats)}

  defp decision_copy(%{itc_money_known?: false}, count),
    do:
      "#{count} purchase #{plural(count, "decision")} awaiting review; ITC amount not recorded for this month."

  defp decision_copy(%{total_tax_paise: 0}, count),
    do: "#{count} purchase #{plural(count, "decision")} awaiting review."

  defp decision_copy(%{settled_tax_paise: 0} = stats, count) do
    "All #{money(stats.total_tax_paise)} of proposed ITC is awaiting #{count} " <>
      "#{plural(count, "decision")}."
  end

  defp decision_copy(stats, count) do
    "#{money(stats.settled_tax_paise)} resolved · #{money(stats.open_tax_paise)} pending review " <>
      "across #{count} #{plural(count, "decision")}."
  end

  defp awaiting_bills_copy(%{itc_money_known?: false}, count),
    do: "#{count} missing #{plural(count, "document")}; ITC amount not recorded for this month."

  defp awaiting_bills_copy(%{settled_tax_paise: 0} = stats, count) do
    "All #{money(stats.total_tax_paise)} of proposed ITC is awaiting #{count} missing " <>
      "#{plural(count, "document")}."
  end

  defp awaiting_bills_copy(stats, count) do
    "#{money(stats.settled_tax_paise)} resolved · #{money(stats.open_tax_paise)} awaiting " <>
      "#{count} missing #{plural(count, "document")}."
  end

  defp reconciled_copy(%{itc_money_known?: false}),
    do: "Purchase reconciliation complete; ITC amount not recorded for this month."

  defp reconciled_copy(stats), do: "#{money(stats.net_itc_effect_paise)} net ITC effect resolved."

  defp lifecycle_copy(%{itc_money_known?: false}, :filed),
    do: "GSTR-3B filed; ITC amount not recorded for this month."

  defp lifecycle_copy(%{itc_money_known?: false}, :signed),
    do: "GSTR-3B signed; ITC amount not recorded for this month."

  defp lifecycle_copy(stats, :filed),
    do: "#{money(stats.net_itc_effect_paise)} net ITC effect · GSTR-3B filed on the GST portal."

  defp lifecycle_copy(stats, :signed),
    do: "#{money(stats.net_itc_effect_paise)} net ITC effect · GSTR-3B ready for portal filing."

  defp review_label(1), do: "Review decision"
  defp review_label(count), do: "Review #{count} decisions"

  defp money(paise), do: format_money(paise, prefix: "₹")

  defp signed_money(paise) when is_number(paise) and paise < 0,
    do: "−" <> format_money(abs(paise), prefix: "₹")

  defp signed_money(paise), do: "+" <> format_money(paise || 0, prefix: "₹")

  defp document_abbreviation(%{"document_type" => "credit_note"}), do: "CN"
  defp document_abbreviation(%{"document_type" => "debit_note"}), do: "DN"
  defp document_abbreviation(_unknown), do: "Document"

  defp row_click(row, client, period) do
    scope = if Register.open_row?(row), do: "needs_you", else: "all"

    JS.patch(
      ~p"/gst/#{client.id}/#{period}/review/purchase?item=#{row["review_item"]}&scope=#{scope}"
    )
  end

  defp status_variant(%{"bucket" => "matched"} = row) do
    if Register.needs_review?(row), do: "warning", else: "success"
  end

  defp status_variant(%{"bucket" => "needs_human"}), do: "warning"
  defp status_variant(%{"bucket" => "value_mismatch"}), do: "error"
  defp status_variant(_row), do: "info"

  # Alarm is spent only on rows that need a decision. When any flag painted a
  # row, 10 of 12 were orange and the ₹48,802 GSTIN problem screamed exactly as
  # loud as a ₹107 scooter bill.
  defp row_accent(row) do
    if Register.open_row?(row) do
      "border-l-2 border-l-warning bg-warning/[0.04]"
    else
      "text-ink-muted"
    end
  end

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"
end
