defmodule NilaWeb.Components.Gst.Month.Purchase do
  use NilaWeb, :html

  @moduledoc "The Purchases and ITC workpaper."

  alias Nila.Gst.Purchase.{Register, Review}
  alias NilaWeb.Components.Gst.Exceptions.Itc
  alias NilaWeb.Components.Gst.Month.Workpaper

  attr :purchase_month, :any, default: nil
  attr :deadline, :any, default: nil
  attr :stats, :any, default: nil
  attr :document_flags, :list, default: []
  attr :rows, :list, required: true
  attr :visible_rows, :list, required: true
  attr :client, :map, required: true
  attr :period, :string, required: true
  attr :gstr3b_signoff, :any, default: nil
  attr :itc, :any, default: nil
  attr :case_lines, :list, default: []
  attr :track_state, :atom, required: true
  attr :review, :any, required: true
  attr :open_folds, :any, default: MapSet.new()
  attr :register_form, :any, required: true
  attr :recon_filter, :atom, required: true
  attr :action_filter, :atom, required: true
  attr :register_sort, :atom, required: true
  attr :gstr2b_in, :boolean, default: false
  attr :asks, :list, default: []
  slot :source

  def register(assigns) do
    carried_itc = carried_itc(assigns.case_lines, assigns.period)
    action_counts = action_counts(assigns.review)

    assigns =
      assigns
      |> assign(:verdict, verdict_state(assigns))
      |> assign(:carried_itc, carried_itc)
      |> assign(:action_counts, action_counts)
      |> assign(:scorecards, reconciliation_scorecards(assigns.rows, assigns.review))
      |> assign(:required_actions, Enum.take(assigns.review.needs_you, 8))
      |> assign(:first_action, first_visible_action(assigns.visible_rows, assigns.review))

    ~H"""
    <section :if={@purchase_month} id="month-register" class="space-y-section">
      <header
        id="gstr3b-verdict"
        class="border-base-300 moonlight-soft rounded-box space-y-block border p-6"
      >
        <div class="flex flex-wrap items-start justify-between gap-4">
          <div class="min-w-0 space-y-1">
            <p class="text-ink-subtle text-label font-semibold uppercase">Purchase position</p>
            <h2 class="font-display text-base-content text-h3 font-normal">Purchases &amp; ITC</h2>
            <p id="gstr3b-itc-position" class="text-body text-ink-muted max-w-3xl">{@verdict.copy}</p>
            <p
              :if={
                @action_counts.decisions > 0 or @action_counts.documents > 0 or
                  @action_counts.waiting > 0
              }
              class="text-base-content text-ui font-medium"
            >
              <span :if={@action_counts.decisions > 0}>{@action_counts.decisions} {plural(
                @action_counts.decisions,
                "decision"
              )}</span>
              <span :if={@action_counts.decisions > 0 and @action_counts.documents > 0}> · </span>
              <span :if={@action_counts.documents > 0}>{@action_counts.documents} {plural(
                @action_counts.documents,
                "document"
              )} to collect</span>
              <span :if={
                @action_counts.waiting > 0 and
                  (@action_counts.decisions > 0 or @action_counts.documents > 0)
              }> · </span>
              <span :if={@action_counts.waiting > 0}>{@action_counts.waiting} waiting on client</span>
            </p>
          </div>
          <div class="flex flex-wrap items-center gap-2">
            <.button
              :if={@track_state == :need_2b}
              id="purchase-bring-gstr2b"
              navigate={~p"/gst/upload?client_id=#{@client.id}&period=#{@period}"}
              variant="primary"
              size="sm"
            >
              Bring in GSTR-2B
            </.button>
            <.button
              :if={@first_action && (@action_counts.decisions > 0 or @action_counts.documents > 0)}
              id="gstr3b-review-required"
              patch={purchase_review_path(@client, @period, @first_action.id, :needs_you)}
              variant="primary"
              size="sm"
            >
              Review next action
            </.button>
            <.button
              :if={
                is_nil(@first_action) and @track_state != :need_2b and
                  @action_counts.waiting == 0
              }
              id="purchase-open-gstr3b"
              patch={~p"/gst/#{@client.id}/#{@period}?track=gstr3b"}
              variant="primary"
              size="sm"
            >
              Open GSTR-3B
            </.button>
          </div>
        </div>
      </header>

      <Workpaper.section_nav links={
        [
          %{id: "gstr3b-reconciliation-scorecard", label: "Reconciliation"},
          @required_actions != [] && %{id: "purchase-required-actions", label: "Required actions"},
          %{id: "purchase-controls", label: "Controls"},
          %{id: "gstr3b-register", label: "Register"},
          %{id: "gstr3b-source-documents", label: "Evidence"},
          %{id: "purchase-transition", label: "GSTR-3B"}
        ]
        |> Enum.filter(&is_map/1)
      } />

      <section id="gstr3b-reconciliation-scorecard" class="space-y-block scroll-mt-28">
        <div>
          <h3 class="text-base-content text-h4 font-semibold">Reconciliation population</h3>
          <p class="text-ink-muted text-ui">
            Machine matching state for the whole purchase register. Select a bucket to filter the register.
          </p>
        </div>
        <div class="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
          <button
            :for={card <- @scorecards}
            type="button"
            id={"purchase-score-#{card.key}"}
            phx-click="filter-purchase-reconciliation"
            phx-value-filter={card.filter}
            class="border-base-300 nila-purchase-scorecard rounded-box space-y-1 border p-4 text-left transition"
            data-selected={to_string(@recon_filter == card.filter)}
            aria-pressed={to_string(@recon_filter == card.filter)}
          >
            <span class="nila-purchase-scorecard-label text-ink-subtle text-label font-semibold uppercase">
              {card.label}
            </span>
            <span class="text-base-content text-lead block font-semibold tabular-nums">{card.count}</span>
            <span class="text-ink-muted text-ui block tabular-nums">{format_money(card.tax_paise,
              prefix: "₹"
            )} tax</span>
          </button>
        </div>
      </section>

      <section
        :if={@required_actions != []}
        id="purchase-required-actions"
        class="space-y-block scroll-mt-28"
      >
        <div>
          <h3 class="text-base-content text-h4 font-semibold">Required actions</h3>
          <p class="text-ink-muted text-ui">
            Judgement, corrections and missing evidence remain separate from machine matching state.
          </p>
        </div>
        <div class="bg-base-100 border-base-300 divide-base-300 rounded-box divide-y border">
          <article
            :for={item <- @required_actions}
            id={"purchase-required-#{item.id}"}
            class="flex flex-wrap items-center gap-4 px-4 py-3"
          >
            <div class="min-w-0 flex-1">
              <div class="flex flex-wrap items-center gap-2">
                <.badge variant={action_variant(item)}>{action_label(item)}</.badge>
                <p class="text-base-content text-ui font-semibold">
                  {item.invoice_number || "—"} · {item.vendor}
                </p>
              </div>
              <p class="text-body text-ink-muted mt-1">{item.reason}</p>
            </div>
            <p class="text-base-content text-ui font-mono tabular-nums">
              {format_money(item.tax_paise, prefix: "₹")}
            </p>
            <.button
              patch={purchase_review_path(@client, @period, item.id, :needs_you)}
              variant="outline"
              size="xs"
            >
              {action_button(item)}
            </.button>
          </article>
        </div>
      </section>

      <section id="purchase-controls" class="space-y-block scroll-mt-28">
        <div>
          <h3 class="text-base-content text-h4 font-semibold">Purchase controls</h3>
          <p class="text-ink-muted text-ui">
            Open the bridge or evidence population when you need the supporting schedule.
          </p>
        </div>
        <div class="bg-base-100 border-base-300 divide-base-300 rounded-box divide-y border">
          <.fold
            id="purchase-control-coverage"
            open={MapSet.member?(@open_folds, "purchase-control-coverage")}
            class="px-4"
            summary_class="py-4 text-base-content w-full"
          >
            <:summary>
              <.fold_summary title="Purchase register and GSTR-2B coverage">
                <:detail>
                  {@stats.invoices} supplied documents · {@stats.gstr2b_only} 2B-only entries · {@stats.rows} positions
                </:detail>
                <:status>
                  <.badge variant={if @gstr2b_in, do: "neutral", else: "warning"}>
                    {if @gstr2b_in, do: "Compared", else: "2B not in"}
                  </.badge>
                </:status>
              </.fold_summary>
            </:summary>
            <dl class="grid gap-4 pb-4 sm:grid-cols-3">
              <div>
                <dt class="text-ink-subtle text-label uppercase">Matched</dt><dd class="text-base-content text-body font-semibold">
                  {@stats.matched}
                </dd>
              </div>
              <div>
                <dt class="text-ink-subtle text-label uppercase">Open positions</dt><dd class="text-base-content text-body font-semibold">
                  {@stats.open}
                </dd>
              </div>
              <div>
                <dt class="text-ink-subtle text-label uppercase">2B-only</dt><dd class="text-base-content text-body font-semibold">
                  {@stats.gstr2b_only}
                </dd>
              </div>
            </dl>
          </.fold>

          <.fold
            :if={@itc}
            id="gstr3b-reconciliation"
            open={MapSet.member?(@open_folds, "gstr3b-reconciliation")}
            class="px-4"
            summary_class="py-4 text-base-content w-full"
          >
            <:summary>
              <.fold_summary title="Current ITC proposal bridge">
                <:detail>How portal-reported credit becomes the current proposed ITC.</:detail>
                <:status>
                  <.badge variant={if @stats.need_decision > 0, do: "warning", else: "neutral"}>
                    {if @stats.need_decision > 0, do: "Review open", else: "Current"}
                  </.badge>
                </:status>
              </.fold_summary>
            </:summary>
            <div class="space-y-related pb-4">
              <h3 class="text-base-content text-body font-semibold">ITC working</h3>
              <Itc.itc_bridge itc={@itc} stats={@stats} id="gstr3b-itc-bridge" />
            </div>
          </.fold>

          <.fold
            :if={@carried_itc != []}
            id="purchase-control-prior-itc"
            open={MapSet.member?(@open_folds, "purchase-control-prior-itc")}
            class="px-4"
            summary_class="py-4 text-base-content w-full"
          >
            <:summary>
              <.fold_summary title="Prior-period ITC">
                <:detail>
                  {length(@carried_itc)} earlier {plural(length(@carried_itc), "position")}
                </:detail>
                <:status>
                  <.badge variant="info">Carried</.badge>
                </:status>
              </.fold_summary>
            </:summary>
            <div id="gstr3b-carried-itc" class="space-y-related pb-4">
              <h4 class="text-base-content text-body font-semibold">Prior-period ITC</h4>
              <div class="border-base-300 divide-base-300 rounded-box divide-y border">
                <div
                  :for={line <- @carried_itc}
                  id={"gstr3b-carried-itc-#{line.case_id}"}
                  class="gap-related grid items-center px-4 py-3 sm:grid-cols-[7rem_minmax(0,1fr)_auto]"
                >
                  <div class="text-ink-subtle text-ui font-medium">
                    {carried_origin(line)}
                  </div>
                  <div class="min-w-0">
                    <div class="text-base-content text-ui truncate font-medium">
                      {line.invoice_number || "—"} · {line.vendor}
                    </div><div class="text-ink-subtle text-ui">{carried_status(line)}</div>
                  </div>
                  <div class="text-base-content text-ui font-mono">
                    {format_money(line.tax_paise, prefix: "₹")}
                  </div>
                </div>
              </div>
            </div>
          </.fold>

          <.fold
            :if={@itc && (@itc["awaiting_document_paise"] || 0) > 0}
            id="purchase-control-missing-evidence"
            open={MapSet.member?(@open_folds, "purchase-control-missing-evidence")}
            class="px-4"
            summary_class="py-4 text-base-content w-full"
          >
            <:summary>
              <.fold_summary title="Missing-evidence coverage">
                <:detail>
                  {@stats.awaiting_bills} supporting {plural(@stats.awaiting_bills, "document")} not on file
                </:detail>
                <:status>
                  <.badge variant="warning">Evidence pending</.badge>
                </:status>
              </.fold_summary>
            </:summary>
            <div class="pb-4">
              <Itc.supporting_evidence
                itc={@itc}
                stats={@stats}
                id="purchase-itc-supporting-evidence"
              />
            </div>
          </.fold>
        </div>
      </section>

      <section id="gstr3b-register" class="space-y-block scroll-mt-28">
        <div class="flex flex-wrap items-end justify-between gap-4">
          <div>
            <h3 class="text-base-content text-h4 font-semibold">Purchase register</h3>
            <p class="text-ink-muted text-ui">
              {length(@visible_rows)} of {@stats.rows} positions shown · {@stats.invoices} supplied {plural(
                @stats.invoices,
                "document"
              )} · {@stats.gstr2b_only} additional 2B-only {plural(@stats.gstr2b_only, "entry")}
            </p>
          </div>
          <.button
            :if={@first_action}
            id="purchase-register-review-next"
            patch={purchase_review_path(@client, @period, @first_action.id, :needs_you)}
            variant="outline"
            size="xs"
          >Review next</.button>
        </div>

        <div class="grid gap-3 xl:grid-cols-[minmax(16rem,1fr)_auto_auto] xl:items-end">
          <.form
            for={@register_form}
            id="purchase-register-search"
            phx-change="search-purchase-register"
            class="w-full max-w-sm"
          >
            <.input
              field={@register_form[:query]}
              type="search"
              label="Search purchase register"
              placeholder="Invoice, vendor or GSTIN"
            />
          </.form>
          <div class="overflow-x-auto">
            <.segmented_control
              id="purchase-action-filters"
              items={[
                {:all, "All actions"},
                {:decisions, "Decisions"},
                {:documents, "To collect"},
                {:waiting, "Waiting"},
                {:resolved, "Resolved"}
              ]}
              selected={@action_filter}
              on_change="filter-purchase-action"
              value_name="filter"
            />
          </div>
          <.segmented_control
            id="purchase-register-sort"
            items={[
              {:register, "Register"},
              {:materiality, "Tax high-low"},
              {:vendor, "Vendor"}
            ]}
            selected={@register_sort}
            on_change="sort-purchase-register"
            value_name="sort"
          />
        </div>

        <.data_table
          id="gst-register"
          rows={@visible_rows}
          row_id={fn row -> row["dom_id"] end}
          row_click={&row_click(&1, @client, @period)}
          row_class={&row_accent/1}
          min_width="min-w-[1040px]"
        >
          <:col :let={row} label="Document no">
            <div class="flex items-center gap-2">
              <.icon
                :if={Register.open_row?(row)}
                name="hero-exclamation-triangle-mini"
                class="text-warning size-4 shrink-0"
              /><span class="font-medium">{row["invoice_number"] || "—"}</span><span
                :if={row["document_type"] != "invoice"}
                class="text-ink-subtle text-ui"
              >{document_abbreviation(row)}</span>
            </div>
          </:col>
          <:col :let={row} label="Vendor">{row["vendor_name"]}</:col>
          <:col :let={row} label="Taxable" align="right">
            {format_money(row["taxable_paise"], prefix: "₹")}
          </:col>
          <:col :let={row} label="Current ITC" align="right">
            <span class={row["itc_effect_paise"] < 0 && "text-error"}>{signed_money(
              row["itc_effect_paise"]
            )}</span>
          </:col>
          <:col :let={row} label="Machine reconciliation">
            <.badge variant={status_variant(row)}>{row["bucket_label"]}</.badge>
          </:col>
          <:col :let={row} label="Human action">
            <span class="text-ink-muted text-ui">{purchase_human_state(row, @review)}</span>
          </:col>
          <:col :let={row} label="Note" class="max-w-sm">
            <span :if={Register.annotated_row?(row)} class="text-base-content block truncate">{row[
              "verdict"
            ]}</span><span
              :if={Register.annotated_row?(row) and row["next_action"]}
              class="text-ink-subtle text-ui mt-0.5 block truncate"
            >{row["next_action"]}</span>
          </:col>
          <:empty>No purchase positions match these filters.</:empty>
        </.data_table>
      </section>

      <section id="gstr3b-source-documents" class="space-y-block scroll-mt-28">
        <div>
          <h3 class="text-base-content text-h4 font-semibold">Evidence and collection history</h3>
          <p class="text-ink-muted text-ui">
            Source packets, GSTR-2B basis and processing facts behind this position.
          </p>
        </div>
        <p id="purchase-gstr2b-freshness" class="text-base-content text-ui font-medium">
          {if @gstr2b_in,
            do: "Reconciled against the GSTR-2B data currently in Nila.",
            else: "No GSTR-2B population is available for this month."}
        </p>
        {render_slot(@source)}
        <button
          :if={@asks != []}
          type="button"
          phx-click="open-chase-history"
          class="text-moon text-ui font-semibold"
        >View {length(@asks)} recorded {plural(length(@asks), "request")}</button>
        <div :if={@document_flags != []} id="gst-document-flags" class="space-y-related">
          <p class="text-ink-subtle text-label font-semibold uppercase">Source processing</p>
          <div
            :for={{flag, index} <- Enum.with_index(@document_flags)}
            id={"gst-document-flag-#{index}"}
            class="border-base-300 rounded-box flex flex-wrap items-center gap-3 border px-4 py-3"
          >
            <span class="text-ink-subtle text-ui font-medium">{issue_label(flag["code"])}</span><span class="text-body text-ink-muted min-w-0 flex-1">{flag[
              "reason"
            ]}</span>
          </div>
        </div>
      </section>

      <section
        id="purchase-transition"
        class="border-base-300 rounded-box flex scroll-mt-28 flex-wrap items-center justify-between gap-4 border p-6"
      >
        <div>
          <h3 class="text-base-content text-h4 font-semibold">Continue to GSTR-3B</h3><p class="text-ink-muted text-ui">
            <%= if @action_counts.waiting > 0 do %>
              {@action_counts.waiting} {plural(@action_counts.waiting, "document request")} still waiting on the client. GSTR-3B will carry that pending evidence visibly.
            <% else %>
              The final return uses this current or frozen ITC position together with outward liability from GSTR-1.
            <% end %>
          </p>
        </div>
        <.button
          id="purchase-transition-gstr3b"
          patch={~p"/gst/#{@client.id}/#{@period}?track=gstr3b"}
          variant={if @action_counts.waiting > 0, do: "outline", else: "primary"}
          size="sm"
        >
          {if @action_counts.waiting > 0, do: "Continue with pending evidence", else: "Open GSTR-3B"}
        </.button>
      </section>
    </section>
    """
  end

  defp reconciliation_scorecards(rows, review) do
    definitions = [
      {:all, "All reconciliation", :all, fn _row -> true end},
      {:matched, "Matched", :matched, &(&1["bucket"] == "matched")},
      {:suggested, "Suggested / confirm", :needs_human, &(&1["bucket"] == "needs_human")},
      {:value_difference, "Value difference", :value_mismatch,
       &(&1["bucket"] == "value_mismatch")},
      {:not_in_2b, "Not in GSTR-2B", :in_books_not_2b, &(&1["bucket"] == "in_books_not_2b")},
      {:two_b_only, "GSTR-2B only", :in_2b_not_books, &(&1["bucket"] == "in_2b_not_books")},
      {:resolved, "Resolved by a human", :resolved, &human_resolved_row?(&1, review)}
    ]

    Enum.map(definitions, fn {key, label, filter, predicate} ->
      matching = Enum.filter(rows, predicate)

      %{
        key: key,
        label: label,
        filter: filter,
        count: length(matching),
        tax_paise: Enum.sum(Enum.map(matching, &Register.row_tax/1))
      }
    end)
  end

  defp human_resolved_row?(row, review) do
    case Review.lookup(review.all, row["review_item"]) do
      %{resolved: true} -> true
      _item -> false
    end
  end

  defp first_visible_action(rows, review) do
    rows
    |> Enum.map(fn row -> Review.lookup(review.needs_you, row["review_item"]) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.id)
    |> Enum.find(&actionable_now?/1)
  end

  defp action_counts(review) do
    Enum.reduce(review.all, %{decisions: 0, documents: 0, waiting: 0, resolved: 0}, fn item,
                                                                                       counts ->
      cond do
        item.resolved ->
          Map.update!(counts, :resolved, &(&1 + 1))

        item.kind == :gstr2b and not is_nil(item.asked_at) ->
          Map.update!(counts, :waiting, &(&1 + 1))

        item.kind == :gstr2b ->
          Map.update!(counts, :documents, &(&1 + 1))

        true ->
          Map.update!(counts, :decisions, &(&1 + 1))
      end
    end)
  end

  defp actionable_now?(%{kind: :gstr2b, asked_at: asked_at}), do: is_nil(asked_at)
  defp actionable_now?(_item), do: true

  defp action_label(%{resolved: true}), do: "Resolved"

  defp action_label(%{kind: :gstr2b, asked_at: asked_at}) when not is_nil(asked_at),
    do: "Waiting externally"

  defp action_label(%{kind: :gstr2b}), do: "Document to collect"
  defp action_label(%{action: :pair}), do: "Confirmation"
  defp action_label(%{action: :ambiguous}), do: "Professional decision"
  defp action_label(%{type: type}) when type in ~w(invoice_number_mismatch), do: "Correction"
  defp action_label(_item), do: "Decision"

  defp action_variant(%{kind: :gstr2b}), do: "info"
  defp action_variant(_item), do: "warning"

  defp action_button(%{kind: :gstr2b, asked_at: asked_at}) when not is_nil(asked_at),
    do: "Inspect request"

  defp action_button(%{kind: :gstr2b}), do: "Collect document"
  defp action_button(_item), do: "Review"

  defp purchase_human_state(row, review) do
    case Review.lookup(review.all, row["review_item"]) do
      nil -> "No recorded action"
      %{resolved: true, outcome: outcome} -> outcome || "Resolved"
      %{kind: :gstr2b, asked_at: asked_at} when not is_nil(asked_at) -> "Waiting on client"
      %{kind: :gstr2b} -> "Document to collect"
      _item -> "Decision open"
    end
  end

  defp purchase_review_path(client, period, item, scope),
    do:
      "/gst/#{client.id}/#{period}/review/purchase?" <>
        URI.encode_query(%{"item" => item, "scope" => to_string(scope)})

  defp carried_itc(case_lines, period) do
    case_lines
    |> Enum.filter(fn line ->
      Enum.any?(line.books_periods ++ line.gstr2b_periods, &(&1 < period)) and
        line.settlement_state not in ~w(claimed excluded)
    end)
    |> Enum.sort_by(&{carried_origin(&1), &1.invoice_number || "", &1.case_id})
  end

  defp carried_origin(line) do
    case Enum.min(line.books_periods ++ line.gstr2b_periods, fn -> nil end) do
      nil -> "Earlier"
      period -> period_label(period)
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

  defp verdict_state(%{stats: nil}), do: %{copy: nil}

  defp verdict_state(%{gstr3b_signoff: %{}, purchase_month: %{filed_at: filed_at}, stats: stats})
       when not is_nil(filed_at), do: %{copy: lifecycle_copy(stats, :filed)}

  defp verdict_state(%{gstr3b_signoff: %{}, stats: stats}),
    do: %{copy: lifecycle_copy(stats, :signed)}

  defp verdict_state(%{stats: %{need_decision: count} = stats}) when count > 0,
    do: %{copy: position_copy(stats, count)}

  defp verdict_state(%{stats: %{awaiting_bills: count} = stats}) when count > 0,
    do: %{copy: awaiting_bills_copy(stats, count)}

  defp verdict_state(%{stats: %{value_disputes: count} = stats}) when count > 0,
    do: %{copy: value_disputes_copy(stats, count)}

  defp verdict_state(%{stats: stats}), do: %{copy: reconciled_copy(stats)}

  defp awaiting_bills_copy(%{itc_money_known?: false}, count),
    do: "#{count} missing #{plural(count, "document")}; ITC amount not recorded for this month."

  defp awaiting_bills_copy(%{settled_tax_paise: 0} = stats, count),
    do:
      "All #{money(stats.total_tax_paise)} of proposed ITC is awaiting #{count} missing #{plural(count, "document")}."

  defp awaiting_bills_copy(stats, count),
    do:
      "#{money(stats.settled_tax_paise)} resolved · #{money(stats.open_tax_paise)} awaiting #{count} missing #{plural(count, "document")}."

  defp value_disputes_copy(%{itc_money_known?: false}, count),
    do:
      "Purchase position prepared with #{count} disclosed value #{plural(count, "difference")}; ITC amount not recorded for this month."

  defp value_disputes_copy(stats, count),
    do:
      "#{money(stats.net_itc_effect_paise)} net ITC effect prepared · #{count} value #{plural(count, "difference")} disclosed in the register."

  defp reconciled_copy(%{itc_money_known?: false}),
    do: "Purchase reconciliation complete; ITC amount not recorded for this month."

  defp reconciled_copy(stats), do: "#{money(stats.net_itc_effect_paise)} net ITC effect resolved."

  defp lifecycle_copy(%{itc_money_known?: false} = stats, :filed),
    do: "GSTR-3B filed; ITC amount not recorded for this month" <> outstanding_evidence(stats)

  defp lifecycle_copy(%{itc_money_known?: false} = stats, :signed),
    do: "GSTR-3B signed; ITC amount not recorded for this month" <> outstanding_evidence(stats)

  defp lifecycle_copy(stats, :filed),
    do:
      "#{money(stats.net_itc_effect_paise)} net ITC effect · GSTR-3B filed on the GST portal" <>
        outstanding_evidence(stats)

  defp lifecycle_copy(stats, :signed),
    do:
      "#{money(stats.net_itc_effect_paise)} net ITC effect · GSTR-3B ready for portal filing" <>
        outstanding_evidence(stats)

  defp outstanding_evidence(%{awaiting_bills: 0}), do: "."

  defp outstanding_evidence(%{awaiting_bills: count}),
    do: " · #{count} supporting #{plural(count, "document")} still missing."

  defp position_copy(%{itc_money_known?: false} = stats, count),
    do:
      "#{count} #{plural(count, "decision")} affect #{stats.open - stats.awaiting_bills} supplied #{plural(stats.open - stats.awaiting_bills, "bill")}" <>
        missing_bills_clause(stats)

  defp position_copy(stats, count),
    do:
      "#{money(stats.settled_tax_paise)} settled · #{count} #{plural(count, "decision")} affect #{money(decision_tax(stats))} of tax" <>
        missing_bills_clause(stats)

  defp missing_bills_clause(%{awaiting_bills: 0}), do: ""

  defp missing_bills_clause(%{itc_money_known?: false} = stats),
    do: " · #{stats.awaiting_bills} #{plural(stats.awaiting_bills, "bill")} missing"

  defp missing_bills_clause(stats),
    do:
      " · #{stats.awaiting_bills} #{plural(stats.awaiting_bills, "bill")} missing for #{money(stats.awaiting_bills_tax_paise)} of tax"

  defp decision_tax(%{open_money_split_known?: true} = stats),
    do: stats.decision_tax_paise + stats.value_dispute_tax_paise

  defp decision_tax(stats), do: stats.open_tax_paise - stats.awaiting_bills_tax_paise

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

  defp status_variant(%{"bucket" => "matched"} = row),
    do: if(Register.needs_review?(row), do: "warning", else: "success")

  defp status_variant(%{"bucket" => "needs_human"}), do: "warning"
  defp status_variant(%{"bucket" => "value_mismatch"}), do: "error"
  defp status_variant(_row), do: "info"

  defp row_accent(row),
    do:
      if(Register.open_row?(row),
        do: "border-l-2 border-l-warning bg-warning/[0.04]",
        else: "text-ink-muted"
      )

  defp plural(1, word), do: word
  defp plural(_count, "entry"), do: "entries"
  defp plural(_count, word), do: word <> "s"
end
