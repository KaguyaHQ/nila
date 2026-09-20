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
    review_available? = assigns.track_state not in [:awaiting_2b, :need_2b]

    action_counts =
      if review_available?,
        do: action_counts(assigns.review),
        else: %{decisions: 0, documents: 0, waiting: 0, resolved: 0}

    first_action =
      if review_available?, do: first_visible_action(assigns.visible_rows, assigns.review)

    required_actions =
      if review_available?, do: Enum.take(assigns.review.needs_you, 8), else: []

    assigns =
      assigns
      |> assign(:verdict, verdict_state(assigns))
      |> assign(:position, position_state(assigns))
      |> assign(:basis_copy, basis_copy(assigns))
      |> assign(:primary_blocker, primary_blocker(assigns))
      |> assign(:next_action_copy, next_action_copy(first_action, assigns, action_counts))
      |> assign(:carried_itc, carried_itc)
      |> assign(:action_counts, action_counts)
      |> assign(:reconciliation_filters, reconciliation_filters(assigns.rows, assigns.review))
      |> assign(:required_actions, required_actions)
      |> assign(:review_available?, review_available?)
      |> assign(:first_action, first_action)

    ~H"""
    <section :if={@purchase_month} id="month-register" class="space-y-section">
      <header
        id="gstr3b-verdict"
        class="bg-panel-surface border-rule rounded-box grid overflow-hidden border lg:grid-cols-[minmax(0,1.6fr)_minmax(18rem,0.8fr)]"
      >
        <section class="bg-quiet space-y-section p-6 lg:p-8">
          <div class="space-y-related min-w-0">
            <p class="text-ink-subtle text-label font-semibold uppercase">Purchase position</p>

            <h2 class="text-base-content text-h4 font-semibold">Purchases &amp; ITC</h2>
          </div>

          <div id="purchase-itc-conclusion" class="space-y-related">
            <p class="text-ink-subtle text-label font-semibold uppercase">{@position.label}</p>

            <p
              :if={@position.amount}
              id="purchase-itc-amount"
              class="font-display text-base-content text-h3 font-normal tabular-nums"
            >
              {@position.amount}
            </p>

            <p
              :if={is_nil(@position.amount)}
              id="purchase-itc-amount-unavailable"
              class="font-display text-base-content text-h3 font-normal"
            >
              {@position.unavailable}
            </p>

            <p id="gstr3b-itc-position" class="text-body text-ink-muted max-w-3xl">{@verdict.copy}</p>
          </div>

          <div
            :if={
              not is_nil(@position.amount) and is_map(@itc) and
                Map.has_key?(@itc, "reported_2b_paise")
            }
            class="space-y-related"
          >
            <p class="text-ink-subtle text-label font-semibold uppercase">
              Basis of current proposal
            </p>
             <Itc.itc_bridge itc={@itc} id="purchase-itc-proposal-basis" />
          </div>
        </section>

        <aside class="border-rule divide-rule divide-y border-t lg:border-t-0 lg:border-l">
          <div id="purchase-itc-basis" class="space-y-related p-6">
            <p class="text-ink-subtle text-label font-semibold uppercase">Current basis</p>

            <p class="text-base-content text-body font-medium">{@basis_copy}</p>
          </div>

          <div id="purchase-primary-blocker" class="space-y-related p-6">
            <div class="flex flex-wrap items-center justify-between gap-2">
              <p class="text-ink-subtle text-label font-semibold uppercase">Main blocker</p>

              <.badge variant={@primary_blocker.variant}>{@primary_blocker.label}</.badge>
            </div>

            <p class="text-body text-ink-muted">{@primary_blocker.copy}</p>
          </div>

          <div id="purchase-next-action" class="space-y-block p-6">
            <div class="space-y-related">
              <p class="text-ink-subtle text-label font-semibold uppercase">Next human action</p>

              <p class="text-base-content text-body font-medium">{@next_action_copy}</p>
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
                :if={@itc && (@itc["pending_paise"] || 0) > 0}
                id="purchase-set-outstanding-treatment"
                navigate={~p"/gst/#{@client.id}/#{@period}/purchases/register?filter=treatment"}
                size="sm"
              >Set ITC treatment</.button>
              <.button
                :if={
                  is_nil(@first_action) and @review_available? and @action_counts.waiting == 0 and
                    (@itc["pending_paise"] || 0) == 0
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
        </aside>
      </header>

      <Workpaper.section_nav links={
        [
          @required_actions != [] && %{id: "purchase-required-actions", label: "Required actions"},
          %{id: "purchase-controls", label: "Controls"},
          %{id: "gstr3b-register", label: "Register"},
          %{id: "gstr3b-source-documents", label: "Evidence"},
          %{id: "purchase-transition", label: "GSTR-3B"}
        ]
        |> Enum.filter(&is_map/1)
      } />
      <section
        :if={@required_actions != []}
        id="purchase-required-actions"
        class="space-y-block scroll-mt-28"
      >
        <div class="space-y-related">
          <h3 class="text-base-content text-h4 font-semibold">Required actions</h3>

          <p class="text-ink-muted text-ui">
            Judgement, corrections and missing evidence remain separate from machine matching state.
          </p>
        </div>

        <div class="bg-panel-surface border-rule divide-rule rounded-box divide-y border">
          <article
            :for={item <- @required_actions}
            id={"purchase-required-#{item.id}"}
            class="flex flex-wrap items-center gap-4 px-4 py-3"
          >
            <div class="min-w-0 flex-1">
              <div class="flex flex-wrap items-center gap-2">
                <.badge variant={action_variant(item)}>{action_label(item)}</.badge>

                <p class="text-base-content text-ui min-w-0 font-semibold wrap-break-word">
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

        <div class="bg-panel-surface border-rule divide-rule rounded-box divide-y border">
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
            :if={@review_available? and @itc}
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

              <div class="border-rule divide-rule rounded-box divide-y border">
                <div
                  :for={line <- @carried_itc}
                  id={"gstr3b-carried-itc-#{line.case_id}"}
                  class="gap-related grid items-center px-4 py-3 sm:grid-cols-[7rem_minmax(0,1fr)_auto]"
                >
                  <div class="text-ink-subtle text-ui font-medium">
                    {carried_origin(line)}
                  </div>

                  <div class="min-w-0">
                    <div
                      class="text-base-content text-ui truncate font-medium"
                      title={"#{line.invoice_number || "—"} · #{line.vendor}"}
                    >
                      {line.invoice_number || "—"} · {line.vendor}
                    </div><div class="text-ink-subtle text-ui">{carried_status(line)}</div>
                  </div>

                  <div class="text-base-content text-ui font-mono whitespace-nowrap tabular-nums">
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

        <div
          :if={@review_available?}
          id="purchase-reconciliation-filters"
          class="space-y-related"
        >
          <div class="flex flex-wrap items-baseline gap-2">
            <p class="text-base-content text-ui font-semibold">Filter by machine reconciliation</p>

            <p class="text-ink-muted text-ui">
              This filters rows; it does not establish ITC eligibility.
            </p>
          </div>

          <div class="flex flex-wrap gap-1" role="group" aria-label="Machine reconciliation filter">
            <.button
              :for={filter <- @reconciliation_filters}
              id={"purchase-filter-#{filter.key}"}
              type="button"
              phx-click="filter-purchase-reconciliation"
              phx-value-filter={filter.filter}
              variant={if(@recon_filter == filter.filter, do: "soft", else: "ghost")}
              size="xs"
              aria-pressed={to_string(@recon_filter == filter.filter)}
            >
              <span>{filter.label}</span>
              <span class="text-ink-muted tabular-nums">
                {filter.count}<span :if={@recon_filter == filter.filter and filter.tax_paise != 0}> · {format_money(
                  filter.tax_paise,
                  prefix: "₹"
                )} tax</span>
              </span>
            </.button>
          </div>
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

          <div :if={@review_available?} class="overflow-x-auto">
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
          row_click={&row_click(&1, @client, @period, @review_available?)}
          row_class={&row_accent(&1, @review_available?)}
          mode="worklist"
          min_width="min-w-[1040px]"
        >
          <:col :let={row} label="Document no" row_header>
            <div class="flex items-center gap-2">
              <.icon
                :if={@review_available? and Register.open_row?(row)}
                name="hero-exclamation-triangle-mini"
                class="text-warning size-4 shrink-0"
              /><span class="font-mono font-medium whitespace-nowrap">{row["invoice_number"] || "—"}</span><span
                :if={row["document_type"] != "invoice"}
                class="text-ink-subtle text-ui"
              >{document_abbreviation(row)}</span>
            </div>
          </:col>

          <:col :let={row} label="Vendor">
            <span class="wrap-break-word">{row["vendor_name"]}</span>
          </:col>

          <:col :let={row} label="Taxable" align="right">
            {format_money(row["taxable_paise"], prefix: "₹")}
          </:col>

          <:col :let={row} label="Current ITC" align="right">
            <span class={row["itc_effect_paise"] < 0 && "nila-purchase-itc-negative"}>{signed_money(
              row["itc_effect_paise"]
            )}</span>
          </:col>

          <:col :let={row} label="Machine reconciliation">
            <.badge :if={@review_available?} variant={status_variant(row)}>
              {row["bucket_label"]}
            </.badge>

            <span :if={!@review_available?} class="text-ink-muted text-ui">
              Waiting for GSTR-2B
            </span>
          </:col>

          <:col :let={row} label="Human action">
            <span class="text-ink-muted text-ui">
              {purchase_human_state(row, @review, @review_available?)}
            </span>
          </:col>

          <:col :let={row} label="Note" class="max-w-sm">
            <span :if={Register.annotated_row?(row)} class="text-base-content block wrap-break-word">{row[
              "verdict"
            ]}</span><span
              :if={Register.annotated_row?(row) and row["next_action"]}
              class="mt-related text-ink-subtle text-ui block wrap-break-word"
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
            class="border-rule rounded-box flex flex-wrap items-center gap-3 border px-4 py-3"
          >
            <span class="text-ink-subtle text-ui font-medium">{issue_label(flag["code"])}</span><span class="text-body text-ink-muted min-w-0 flex-1">{flag[
              "reason"
            ]}</span>
          </div>
        </div>
      </section>

      <section
        id="purchase-transition"
        class="border-rule rounded-box flex scroll-mt-28 flex-wrap items-center justify-between gap-4 border p-6"
      >
        <div>
          <h3 class="text-base-content text-h4 font-semibold">Continue to GSTR-3B</h3><p class="text-ink-muted text-ui">
            <%= cond do %>
              <% @track_state == :awaiting_2b -> %>
                GSTR-3B waits until the portal publishes GSTR-2B for this period.
              <% @track_state == :need_2b -> %>
                Bring in the published GSTR-2B before continuing to the final return.
              <% @action_counts.waiting > 0 -> %>
                {@action_counts.waiting} {plural(@action_counts.waiting, "document request")} still waiting on the client. GSTR-3B will carry that pending evidence visibly.
              <% true -> %>
                The final return uses this current or frozen ITC position together with outward liability from GSTR-1.
            <% end %>
          </p>
        </div>

        <.button
          :if={@review_available?}
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

  defp reconciliation_filters(rows, review) do
    definitions = [
      {:all, "All", :all, fn _row -> true end},
      {:matched, "Matched", :matched, &(&1["bucket"] == "matched")},
      {:suggested, "Suggested", :needs_human, &(&1["bucket"] == "needs_human")},
      {:value_difference, "Value difference", :value_mismatch,
       &(&1["bucket"] == "value_mismatch")},
      {:not_in_2b, "Not in GSTR-2B", :in_books_not_2b, &(&1["bucket"] == "in_books_not_2b")},
      {:two_b_only, "GSTR-2B only", :in_2b_not_books, &(&1["bucket"] == "in_2b_not_books")},
      {:resolved, "Human-resolved", :resolved, &human_resolved_row?(&1, review)}
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

  defp purchase_human_state(_row, _review, false), do: "Waiting for GSTR-2B"

  defp purchase_human_state(row, review, true) do
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

  defp position_state(%{track_state: :awaiting_2b}),
    do: %{label: "ITC position", amount: nil, unavailable: "Awaiting GSTR-2B"}

  defp position_state(%{track_state: :need_2b}),
    do: %{label: "ITC position", amount: nil, unavailable: "GSTR-2B not imported"}

  defp position_state(%{stats: %{itc_money_known?: false}}),
    do: %{label: "ITC position", amount: nil, unavailable: "Amount not recorded"}

  defp position_state(%{itc: %{"claimable_paise" => paise}} = assigns)
       when is_integer(paise) do
    label =
      cond do
        not is_nil(assigns.purchase_month.filed_at) -> "ITC in filed GSTR-3B"
        not is_nil(assigns.gstr3b_signoff) -> "Frozen ITC position"
        true -> "Current proposed ITC"
      end

    %{
      label: label,
      amount: Nila.Formatters.format_money_with_paise(paise),
      unavailable: nil
    }
  end

  defp position_state(_assigns),
    do: %{label: "ITC position", amount: nil, unavailable: "Amount not recorded"}

  defp basis_copy(%{track_state: :awaiting_2b}),
    do: "The portal has not published GSTR-2B for this period, so no comparison exists yet."

  defp basis_copy(%{track_state: :need_2b}),
    do: "GSTR-2B is available but not in Nila, so no portal comparison exists yet."

  defp basis_copy(%{stats: %{itc_money_known?: false}}),
    do:
      "The register and reconciliation remain available, but this snapshot did not record an ITC amount."

  defp basis_copy(%{gstr3b_signoff: %{}, itc: %{"reported_2b_paise" => reported}}),
    do:
      "Frozen from #{precise_money(reported)} reported in GSTR-2B and the decisions recorded at sign-off."

  defp basis_copy(%{itc: %{"reported_2b_paise" => reported}}),
    do:
      "GSTR-2B reports #{precise_money(reported)} in this period. Proposed ITC uses recorded treatment decisions, including credit carried from earlier periods."

  defp basis_copy(_assigns),
    do: "Derived from the current purchase register and the evidence recorded in this workpaper."

  defp primary_blocker(%{track_state: :awaiting_2b}),
    do: %{
      label: "Waiting for 2B",
      variant: "info",
      copy: "The portal has not published GSTR-2B for this period; nobody can reconcile it yet."
    }

  defp primary_blocker(%{track_state: :need_2b}),
    do: %{
      label: "2B not in",
      variant: "warning",
      copy:
        "The purchase register cannot be compared with the portal population until GSTR-2B is brought in."
    }

  defp primary_blocker(%{itc: %{"pending_paise" => pending}}) when pending > 0,
    do: %{
      label: "ITC treatment needed",
      variant: "warning",
      copy: "#{precise_money(pending)} still needs a claim, later or exclusion decision."
    }

  defp primary_blocker(%{stats: %{need_decision: count} = stats, review: review, itc: itc})
       when count > 0 do
    decision_count =
      Enum.count(review.all, &(!&1.resolved and &1.kind != :gstr2b))

    if decision_count == 0 and stats.awaiting_bills > 0 do
      evidence_blocker(stats)
    else
      pending = itc && itc["pending_decision_paise"]
      display_count = if decision_count > 0, do: decision_count, else: count

      copy =
        if is_integer(pending) and pending > 0,
          do:
            "#{display_count} #{plural(display_count, "decision")} remain open; #{precise_money(pending)} is withheld pending reconciliation decisions.",
          else:
            "#{display_count} #{plural(display_count, "decision")} can still change the purchase treatment."

      %{label: "Decision required", variant: "warning", copy: copy}
    end
  end

  defp primary_blocker(%{stats: %{awaiting_bills: count} = stats}) when count > 0,
    do: evidence_blocker(stats)

  defp primary_blocker(%{stats: %{value_disputes: count}}) when count > 0,
    do: %{
      label: "Difference disclosed",
      variant: "info",
      copy:
        "#{count} value #{plural(count, "difference")} remain disclosed in the register; the proposal uses the GSTR-2B amount for those supplies."
    }

  defp primary_blocker(%{track_state: :filed}),
    do: %{
      label: "Filed",
      variant: "neutral",
      copy:
        "The recorded GSTR-3B filing now governs; this workpaper remains its supporting evidence."
    }

  defp primary_blocker(%{track_state: :signed}),
    do: %{
      label: "Position frozen",
      variant: "info",
      copy:
        "No purchase decision can change this signed snapshot unless the sign-off is unlocked."
    }

  defp primary_blocker(_assigns),
    do: %{
      label: "No open blocker",
      variant: "neutral",
      copy: "No purchase decision or missing-document position remains open in this workpaper."
    }

  defp evidence_blocker(stats),
    do: %{
      label: "Evidence pending",
      variant: "info",
      copy:
        "#{stats.awaiting_bills} #{plural(stats.awaiting_bills, "supply")} appear in GSTR-2B without invoices on file. #{precise_money(stats.awaiting_bills_tax_paise)} remains inside the proposal until possession is resolved."
    }

  defp next_action_copy(_first_action, %{track_state: :awaiting_2b}, _counts),
    do: "Wait for the portal to publish GSTR-2B for this period."

  defp next_action_copy(_first_action, %{track_state: :need_2b}, _counts),
    do: "Bring in GSTR-2B so Nila can compare the register with the portal population."

  defp next_action_copy(
         %{kind: :gstr2b, invoice_number: number, vendor: vendor},
         _assigns,
         _counts
       ),
       do:
         "Collect invoice #{number || "—"} from #{vendor}, or record whether the client holds it."

  defp next_action_copy(
         %{kind: :itc, invoice_number: number, vendor: vendor},
         _assigns,
         _counts
       ),
       do:
         "Review invoice #{number || "—"} from #{vendor} and decide whether to block the credit."

  defp next_action_copy(%{invoice_number: number, vendor: vendor}, _assigns, _counts),
    do: "Review invoice #{number || "—"} from #{vendor} and record the purchase treatment."

  defp next_action_copy(nil, _assigns, %{waiting: count}) when count > 0,
    do: "Wait for the client; #{count} recorded #{plural(count, "request")} remain outstanding."

  defp next_action_copy(nil, %{track_state: state}, _counts) when state in [:signed, :filed],
    do: "Open GSTR-3B to inspect the frozen return and its filing state."

  defp next_action_copy(nil, %{itc: %{"pending_paise" => pending}}, _counts) when pending > 0,
    do: "Set ITC treatment for the remaining invoices."

  defp next_action_copy(nil, _assigns, _counts),
    do: "Open GSTR-3B and continue the return from this purchase position."

  defp precise_money(paise), do: Nila.Formatters.format_money_with_paise(paise || 0)

  defp verdict_state(%{stats: nil}), do: %{copy: nil}

  defp verdict_state(%{track_state: :awaiting_2b}),
    do: %{copy: "Purchase reconciliation has not started because GSTR-2B is not published yet."}

  defp verdict_state(%{track_state: :need_2b}),
    do: %{copy: "Purchase reconciliation has not started because GSTR-2B is not in Nila yet."}

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

  defp row_click(_row, _client, _period, false), do: nil

  defp row_click(row, client, period, true) do
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

  defp row_accent(_row, false), do: nil

  defp row_accent(row, true),
    do:
      if(Register.open_row?(row),
        do: "nila-purchase-open-row border-l-2",
        else: "text-ink-muted"
      )

  defp plural(1, word), do: word
  defp plural(_count, "entry"), do: "entries"
  defp plural(_count, "supply"), do: "supplies"
  defp plural(_count, word), do: word <> "s"
end
