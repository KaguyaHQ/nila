defmodule NilaWeb.Components.Gst.Month.Purchase do
  use NilaWeb, :html

  @moduledoc """
  Purchase reconciliation evidence. Open rows retain their route to the
  exceptions queue; settled rows retain their source-evidence modal.

  The section states its own ITC position and its own completeness before the
  register, in the same order the sales track states them: what the month is
  worth, what the return assembles to, what came in, then the evidence. The
  month-wide verdict band can only ever speak for one track, so a purchase
  position that lives only there disappears whenever sales wins the band.
  """

  alias Nila.Gst.Purchase.Register
  alias NilaWeb.Components.Gst.Exceptions.Itc

  attr :purchase_month, :any, default: nil
  attr :stats, :any, default: nil
  attr :document_flags, :list, default: []
  attr :rows, :list, required: true
  attr :client, :map, required: true
  attr :period, :string, required: true
  attr :gstr3b_signoff, :any, default: nil
  attr :source_files, :integer, default: 0
  attr :pages_read, :integer, default: nil
  attr :itc, :any, default: nil
  slot :source
  slot :assembled
  slot :actions

  @doc "The complete purchase register, always visible as month evidence."
  def register(assigns) do
    assigns = assign(assigns, :verdict, verdict_state(assigns))

    ~H"""
    <section :if={@purchase_month} id="month-register" class="space-y-section">
      <section id="gstr3b-verdict" class="border-base-300 p-block rounded-box border">
        <div class="flex flex-wrap items-start justify-between gap-4">
          <div class="space-y-related">
            <div class="flex flex-wrap items-center gap-2">
              <h2 class="text-base-content text-h4 font-semibold">Purchase reconciliation</h2>
              <.badge variant={@verdict.variant}>{@verdict.label}</.badge>
            </div>
            <p class="text-body text-ink-muted">{@verdict.copy}</p>
          </div>
          <.button
            :if={@stats.need_decision > 0}
            id="gstr3b-review-required"
            navigate={~p"/gst/#{@client.id}/#{@period}/exceptions"}
            variant="primary"
            size="sm"
          >
            Work the {@stats.need_decision} {plural(@stats.need_decision, "decision")}
          </.button>
          <%!-- Nothing left to judge, so the door is the chase, not the queue. --%>
          <.button
            :if={@stats.need_decision == 0 and @stats.awaiting_bills > 0}
            id="gstr3b-request-bills"
            navigate={~p"/gst/#{@client.id}/#{@period}/exceptions"}
            variant="primary"
            size="sm"
          >
            Request the {@stats.awaiting_bills} missing {plural(@stats.awaiting_bills, "bill")}
          </.button>
        </div>
        <dl class="gap-block mt-block grid sm:grid-cols-3">
          <div>
            <dt class="text-ink-subtle text-label font-semibold uppercase">ITC this month</dt>
            <dd
              id="gstr3b-total-itc"
              class="font-display text-base-content text-lead tabular-nums"
            >
              {format_money(@stats.total_tax_paise, prefix: "₹")}
            </dd>
          </div>
          <%!-- Named for what actually holds the money up. When every open rupee
                waits on a document, "riding on decisions" sends the reviewer to
                decide something that cannot be decided. --%>
          <div>
            <dt class="text-ink-subtle text-label font-semibold uppercase">
              {if @stats.need_decision == 0 and @stats.awaiting_bills > 0,
                do: "Awaiting bills",
                else: "Riding on decisions"}
            </dt>
            <dd
              id="gstr3b-open-itc"
              class="font-display text-base-content text-lead tabular-nums"
            >
              {format_money(@stats.open_tax_paise, prefix: "₹")}
            </dd>
          </div>
          <%!-- Settled, not matched. `matched` and `open` are not complements —
                audited-accepted rows sit in neither — so showing those two beside
                the total invites a sum that lands short of the month. Settled is
                the exact complement of open, so the three close. --%>
          <div>
            <dt class="text-ink-subtle text-label font-semibold uppercase">Settled</dt>
            <dd
              id="gstr3b-settled-itc"
              class="font-display text-base-content text-lead tabular-nums"
            >
              {format_money(@stats.settled_tax_paise, prefix: "₹")}
            </dd>
          </div>
        </dl>
      </section>

      {render_slot(@assembled)}

      <section id="gstr3b-completeness" class="space-y-block">
        <h3 class="text-base-content text-body font-semibold">Completeness and reconciliation</h3>

        <%!-- "0 files received" beside "12 invoices extracted" is an impossible
              pair, and printing it flat as fact teaches a reviewer to distrust
              the whole block. A count that cannot be true is a count we do not
              have — a month reconciled from an import or a backfill never had a
              file pass through intake. Say that instead of asserting zero. --%>
        <div class="border-base-300 rounded-box grid gap-4 border p-4 sm:grid-cols-2 lg:grid-cols-4">
          <.control_stat
            label="Source files received"
            value={@source_files}
            unknown={@source_files == 0 and @stats.invoices > 0}
            unknown_note="not recorded for this month"
          />
          <.control_stat :if={@pages_read} label="Bill pages read" value={@pages_read} />
          <.control_stat label="Invoices extracted" value={@stats.invoices} />
          <.control_stat label="Pages with no invoice" value={length(@document_flags)} />
        </div>

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
          <:col :let={row} label="ITC" align="right">
            {format_money(row.tax_paise, prefix: "₹")}
          </:col>
          <:col :let={row} label="Next move">
            <span class="text-ink-muted">{row.next_move}</span>
          </:col>
        </.data_table>

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
            {@stats.invoices} {plural(@stats.invoices, "invoice")} extracted{if @stats.gstr2b_only >
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
          <:col :let={row} label="Inv No">
            <div class="flex items-center gap-2">
              <.icon
                :if={Register.open_row?(row)}
                name="hero-exclamation-triangle-mini"
                class="text-warning size-4 shrink-0"
              />
              <span class="font-medium">{row["invoice_number"] || "—"}</span>
            </div>
          </:col>
          <:col :let={row} label="Vendor">{row["vendor_name"]}</:col>
          <:col :let={row} label="Taxable" align="right">
            {format_money(row["taxable_paise"], prefix: "₹")}
          </:col>
          <:col :let={row} label="Tax total" align="right">
            {format_money(Register.row_tax(row), prefix: "₹")}
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
          <:col :let={row} label="Note" class="max-w-sm">
            <span :if={Register.annotated_row?(row)} class="text-base-content block truncate">
              {row["verdict"]}
            </span>
          </:col>
          <%!-- Adjacent rows do different things on click: an open row leaves for
                the exceptions queue, a settled one opens its evidence here. The
                ⚠ and the accent mean severity, not destination, so the row that
                leaves says so. --%>
          <:col :let={row} label="" align="right">
            <.icon
              :if={Register.open_row?(row)}
              name="hero-arrow-right-mini"
              class="text-ink-faint size-4"
            />
          </:col>
          <:empty>The register is empty for this month.</:empty>
        </.data_table>
      </div>

      {render_slot(@actions)}
    </section>
    """
  end

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
        label: "Bill and 2B agree",
        note: "Matched to the portal, or ruled on and closed",
        count: stats.rows - stats.open,
        tax_paise: stats.settled_tax_paise,
        next_move: "Nothing"
      },
      %{
        key: "decisions",
        label: "Bill supplied, not settled against 2B",
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
        label: "In 2B, bill not supplied",
        note: "The portal reported a supply nobody sent us a document for",
        count: stats.awaiting_bills,
        tax_paise: stats.awaiting_bills_tax_paise,
        next_move: if(stats.awaiting_bills > 0, do: "Ask the client", else: "Nothing")
      }
    ]
  end

  defp verdict_state(%{gstr3b_signoff: %{}, purchase_month: %{filed_at: filed_at}})
       when not is_nil(filed_at),
       do: %{
         variant: "neutral",
         label: "Filed",
         copy: "The signed GSTR-3B is on the GST portal."
       }

  defp verdict_state(%{gstr3b_signoff: %{}}),
    do: %{
      variant: "success",
      label: "Signed",
      copy: "The signed reconciliation is frozen and ready for portal filing."
    }

  # The badge names what this card is: a reconciliation with open decisions. It
  # read "Blocked", which is the GSTR-3B's state, on a card titled "Purchase
  # reconciliation" — the badge and its object disagreed.
  defp verdict_state(%{stats: %{need_decision: count}}) when count > 0,
    do: %{
      variant: "error",
      label: "Needs #{count} #{plural(count, "decision")}",
      copy:
        "#{count} #{plural(count, "decision")} must be worked before the GSTR-3B can be signed."
    }

  # Reconciled as far as the supplied documents allow. Nobody on this page can
  # move it: the portal reported supplies whose bills were never sent, so the
  # next step is a request, not a judgement.
  defp verdict_state(%{stats: %{awaiting_bills: count}}) when count > 0,
    do: %{
      variant: "warning",
      label: "Waiting for bills",
      copy:
        "#{count} #{plural(count, "invoice")} #{verb(count)} in the GSTR-2B with no bill supplied. " <>
          "That credit needs its documents before it can be claimed."
    }

  defp verdict_state(_assigns),
    do: %{
      variant: "success",
      label: "Reconciled",
      copy: "Every purchase bill is settled against the GSTR-2B."
    }

  # The click follows the work. A row that still needs a decision opens the
  # queue at that item; a settled row opens its evidence, which is all there is
  # left to want from it.
  defp row_click(row, client, period) do
    if Register.open_row?(row) and is_binary(row["id"]) do
      JS.navigate(~p"/gst/#{client.id}/#{period}/exceptions?exception=#{row["id"]}")
    else
      JS.push("select-row", value: %{dom_id: row["dom_id"]})
    end
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

  defp verb(1), do: "appears"
  defp verb(_count), do: "appear"
end
