defmodule NilaWeb.Components.Gst.Month.Evidence do
  use NilaWeb, :html

  @moduledoc "Evidence and correction modals for the GST month workbench."

  alias Nila.Gst.Issues
  alias Nila.Gst.Sales.Gstr1
  alias Nila.Gst.Proposals
  alias Nila.Gst.Sales.Values
  alias Nila.Gst.Sales.Workings, as: SalesWorkings
  alias NilaWeb.Components.Gst.Month.Helpers

  attr :show_chase_history, :boolean, required: true
  attr :client, :map, required: true
  attr :period, :string, required: true
  attr :asks, :list, required: true
  attr :source_invoices, :list, default: []
  attr :duplicate_issue, :any, default: nil

  def evidence_modals(assigns) do
    ~H"""
    <.modal
      :if={@show_chase_history}
      id="month-chase-history-modal"
      title={"Asked #{@client.name} · #{period_label(@period)}"}
      on_close="close-chase-history"
      width="wide"
    >
      <.chase_history asks={@asks} />
    </.modal>

    <.duplicate_review_modal
      :if={@duplicate_issue}
      issue={@duplicate_issue}
      invoices={@source_invoices}
      client={@client}
      period={@period}
    />
    """
  end

  attr :issue, :map, required: true
  attr :invoices, :list, required: true
  attr :client, :map, required: true
  attr :period, :string, required: true

  defp duplicate_review_modal(assigns) do
    members = Enum.filter(assigns.invoices, &(&1["id"] in assigns.issue["source_ids"]))
    assigns = assign(assigns, :members, members)

    ~H"""
    <.modal
      id="gstr1-duplicate-review-modal"
      title={"Duplicate invoice #{@issue["invoice"]}"}
      on_close="close-duplicate-review"
      width="extra-wide"
      scrim="document"
    >
      <div class="space-y-block">
        <p class="text-body text-ink-muted">
          Compare every source. Retain one only when these are copies of the same invoice. If OCR misread a number, open that source and correct the extraction instead.
        </p>
        <div class="grid gap-4 lg:grid-cols-2">
          <article
            :for={invoice <- @members}
            id={"gstr1-duplicate-source-#{invoice["id"]}"}
            class="border-base-300 rounded-box space-y-block border p-4"
          >
            <img
              :if={List.first(invoice["image_urls"])}
              src={List.first(invoice["image_urls"])}
              alt={"Source document for invoice #{invoice["invoice_number"]}"}
              class="border-base-300 rounded-box max-h-80 w-full border object-contain"
            />
            <dl class="text-ui grid gap-3 sm:grid-cols-2">
              <div>
                <dt class="text-ink-subtle">Source ID</dt>
                <dd class="text-base-content font-mono">{invoice["id"]}</dd>
              </div>
              <div>
                <dt class="text-ink-subtle">Invoice date</dt>
                <dd class="text-base-content">{format_display_date(invoice["invoice_date"])}</dd>
              </div>
              <div>
                <dt class="text-ink-subtle">Buyer</dt>
                <dd class="text-base-content">{invoice["buyer_name"] || "—"}</dd>
              </div>
              <div>
                <dt class="text-ink-subtle">Taxable + tax</dt>
                <dd class="text-base-content tabular-nums">
                  {Helpers.rupees(Gstr1.extracted_totals(invoice).taxable)} + {Helpers.rupees(
                    Gstr1.extracted_totals(invoice).tax
                  )}
                </dd>
              </div>
            </dl>
            <div class="flex flex-wrap gap-2">
              <.button
                variant="primary"
                size="xs"
                phx-click="resolve-duplicate-copies"
                phx-value-source={invoice["id"]}
              >
                Retain this; exclude {length(@members) - 1} other {if length(@members) == 2,
                  do: "copy",
                  else: "copies"}
              </.button>
              <.button
                variant="outline"
                size="xs"
                patch={
                  sales_review_path(
                    @client,
                    @period,
                    invoice["id"],
                    SalesWorkings.issue_key(@issue)
                  )
                }
              >
                Open to correct number
              </.button>
            </div>
          </article>
        </div>
      </div>
    </.modal>
    """
  end

  attr :selected_invoice, :map, required: true
  attr :issues_by_invoice, :map, required: true
  attr :focused_issue, :string, default: nil
  attr :decisions, :map, required: true
  attr :review_navigation, :map, required: true
  attr :r1_signoff, :any, default: nil
  attr :flagged, :any, required: true
  attr :correcting, :any, default: nil
  attr :derived, :any, default: nil
  attr :target, :any, required: true
  attr :event_target, :string, required: true
  attr :evidence_page, :integer, default: 0
  attr :correction_form, :any, default: nil

  # The trust atom: the scan big enough to read on the left, the full extracted
  # read beside it, and every check an outcome the validation layer already
  # judged — this panel renders verdicts, it never computes one. A failed check
  # is its validation issue rendered in place, so ✓ and an open issue can never
  # disagree about the same fact.
  #
  # The arithmetic is the row: taxable, rate and tax stand in their columns, so
  # the ✓ at the end says "these multiply out" and the claim in longhand rides
  # the tick's tooltip. Printing every passed claim as its own line was fourteen
  # lines of wallpaper for a seven-line bill — the eye wants seven glances down
  # one column, then the totals row, and it is done.
  def invoice_detail(assigns) do
    checks = Gstr1.invoice_checks(assigns.selected_invoice)
    issues = Helpers.invoice_issues(assigns.issues_by_invoice, assigns.selected_invoice)

    failed_checks = Enum.reject(checks, & &1["passed"])

    # Pair a failed check to the issue that speaks for it. Exact `fields`
    # equality used to be enough because one failing line raised one issue; now
    # that lines sharing a code collapse into a single issue, its `fields` is
    # their union and never equals any one line's. Match on the code, then on
    # the line being one the issue covers, so a merged issue still renders
    # in place beside the line that produced it instead of dropping into the
    # list below.
    #
    # An issue is claimed by the first check it covers and by no other. Every
    # failing line of a merged issue matches it, and a card per check put the
    # same text on the page twice under the same DOM id — `issue_dom_id/1`
    # names the issue, and the issue is one — which is invalid HTML and the id
    # LiveView patches by. The later checks fall through to their own ✗ line,
    # so nothing that failed goes unsaid; the question is asked once, where it
    # was raised, because it can only be answered once.
    {pairs, _claimed} =
      Enum.map_reduce(failed_checks, MapSet.new(), fn check, claimed ->
        case issue_for_check(issues, check) do
          nil -> {{check_key(check), nil}, claimed}
          issue -> {{check_key(check), unclaimed(issue, claimed)}, MapSet.put(claimed, issue)}
        end
      end)

    check_issues = Map.new(pairs)

    in_place = check_issues |> Map.values() |> Enum.reject(&is_nil/1)

    open_issues = Enum.filter(issues, &(&1["status"] == "open"))
    focused_issue = Enum.find(issues, &(SalesWorkings.issue_key(&1) == assigns.focused_issue))

    assigns =
      assigns
      |> assign(:failed_checks, failed_checks)
      |> assign(:check_issues, check_issues)
      |> assign(:other_issues, issues -- in_place)
      |> assign(:open_issues, open_issues)
      |> assign(:initial_focus, focused_issue && issue_focus_target(focused_issue))
      |> assign(:review_state, review_state(open_issues))
      |> assign(:read_rows, read_rows(assigns.selected_invoice, checks))
      |> assign(:values, Values.for_invoice(assigns.selected_invoice, assigns.derived))
      |> assign(:all_checks, checks)

    ~H"""
    <%!-- A flex column, not a block: the pane grid below claims the leftover
          height with `flex-1`, which is what lets each pane scroll on its own
          instead of the two of them growing past the workbench. --%>
    <div id="gstr1-evidence-modal" class="space-y-block flex h-full min-h-0 flex-col">
      <div id="gstr1-review-header" class="space-y-related shrink-0">
        <div class="grid items-center gap-3 lg:grid-cols-[1fr_auto_1fr]">
          <button
            type="button"
            id="gstr1-review-previous"
            phx-click="navigate-invoice-review"
            phx-value-direction="previous"
            phx-target={@target}
            disabled={is_nil(@review_navigation.previous)}
            class="hover:text-ink text-ink-subtle text-ui justify-self-start transition disabled:opacity-30"
          >
            ← Previous
          </button>
          <div class="flex flex-wrap items-center justify-center gap-2 text-center">
            <h3 id="gstr1-evidence-modal-title" class="text-base-content text-body font-semibold">
              {@selected_invoice["invoice_number"] || "Invoice"}
            </h3>
            <span class="text-ink-subtle text-ui">{unresolved_label(@open_issues)}</span>
            <.badge variant={@review_state.variant}>{@review_state.label}</.badge>
          </div>
          <button
            type="button"
            id="gstr1-review-next"
            phx-click="navigate-invoice-review"
            phx-value-direction="next"
            phx-target={@target}
            disabled={is_nil(@review_navigation.next)}
            class="hover:text-ink text-ink-subtle text-ui justify-self-end transition disabled:opacity-30"
          >
            Next →
          </button>
        </div>
        <div :if={@open_issues != []} class="flex flex-wrap justify-center gap-2">
          <button
            :for={{issue, index} <- Enum.with_index(@open_issues, 1)}
            type="button"
            data-review-target={issue_focus_target(issue)}
            class="bg-warning/10 hover:bg-warning/20 rounded-field text-base-content text-ui flex items-center gap-1.5 px-2 py-1 font-medium transition-colors"
          >
            <span class="bg-warning/15 rounded-full px-1.5 tabular-nums">{index}</span>
            {issue_chip_label(issue)}
          </button>
        </div>
      </div>

      <div
        id="gstr1-review-workflow"
        phx-hook=".InvoiceReview"
        data-previous={@review_navigation.previous}
        data-next={@review_navigation.next}
        data-initial-focus={@initial_focus}
        data-event-target={@event_target}
        class="gap-block grid min-h-0 flex-1 lg:grid-cols-[minmax(0,1.15fr)_minmax(0,1fr)] lg:grid-rows-[minmax(0,1fr)]"
      >
        <div id="gstr1-evidence-images" class="min-h-0 overflow-y-auto">
          <.evidence_frame
            :if={@selected_invoice["image_urls"] != []}
            id="gstr1-evidence-frame"
            images={@selected_invoice["image_urls"]}
            page={@evidence_page}
            label="Original document"
            on_open="open-evidence"
            on_page="evidence-page"
            target={@target}
          />
          <div
            :if={@selected_invoice["image_urls"] == []}
            class="border-base-300 rounded-box text-body text-ink-muted flex h-40 items-center justify-center border border-dashed"
          >
            No page image for this invoice.
          </div>
        </div>

        <div id="gstr1-review-details" class="space-y-block min-h-0 overflow-y-auto">
          <div id="gstr1-review-buyer" class="scroll-mt-4">
            <div class="text-ink-subtle text-label font-semibold uppercase">Buyer</div>
            <div class="text-base-content text-body mt-1 font-medium">
              {@selected_invoice["buyer_name"] || "—"}
            </div>
            <div class="text-ink-subtle text-ui mt-0.5 font-mono">
              {@selected_invoice["buyer_gstin"] || "—"}
            </div>
          </div>

          <%!-- The decision leads. It used to sit fourth, below a twelve-row line
                table and below the fold — the reader scrolled past the evidence
                to find the question the evidence answers. Leading is enough; it
                was sticky once, from when the whole page scrolled, and in a
                height-bounded pane a block this tall pinned to the top left the
                lines beneath it scrolling through a slot two rows deep. --%>
          <div
            :if={@failed_checks != [] or @other_issues != []}
            id="gstr1-decisions"
            class="bg-base-100 space-y-related pb-3"
          >
            <div :if={@failed_checks != []} id="gstr1-checks" class="space-y-related">
              <div class="text-ink-subtle text-label font-semibold uppercase">
                What didn't check out
              </div>
              <%= for check <- @failed_checks do %>
                <.issue_card
                  :if={@check_issues[check_key(check)]}
                  id={issue_dom_id(@check_issues[check_key(check)])}
                  issue={@check_issues[check_key(check)]}
                  check={check}
                  checks={@all_checks}
                  values={@values}
                  decisions={@decisions}
                  can_correct={
                    issue_correctable?(@check_issues[check_key(check)], @flagged, @selected_invoice)
                  }
                  r1_signoff={@r1_signoff}
                  target={@target}
                />
                <div
                  :if={is_nil(@check_issues[check_key(check)])}
                  class="text-body text-ink-muted flex items-center gap-2"
                >
                  <.icon name="hero-x-mark-mini" class="text-error size-4 shrink-0" />
                  <span>{check_claim(check)}</span>
                </div>
              <% end %>
            </div>

            <div :if={@other_issues != []} class="space-y-related">
              <div class="text-ink-subtle text-label font-semibold uppercase">Issues</div>
              <.issue_card
                :for={issue <- @other_issues}
                id={issue_dom_id(issue)}
                issue={issue}
                checks={@all_checks}
                values={@values}
                decisions={@decisions}
                can_correct={issue_correctable?(issue, @flagged, @selected_invoice)}
                r1_signoff={@r1_signoff}
                target={@target}
              />
            </div>
          </div>

          <div :if={@read_rows != []} class="space-y-related">
            <div class="text-ink-subtle text-label font-semibold uppercase">
              Extracted from the original
            </div>
            <.data_table
              id="gstr1-line-items"
              rows={@read_rows}
              row_id={& &1.dom_id}
              row_class={
                fn row ->
                  ["scroll-mt-4", row.kind == :total && "bg-base-200/40 font-medium"]
                end
              }
              dense
            >
              <:col :let={row} label="Item">
                <span :if={row.kind == :total} class="text-base-content">Lines sum</span>
                <span
                  :if={row.kind == :line}
                  class="block max-w-56 truncate"
                  title={row.line["description"]}
                >
                  {row.line["description"] || "—"}
                </span>
              </:col>
              <:col :let={row} label="HSN / SAC">
                <div :if={row.kind == :line} class="max-w-44">
                  <span class="font-mono">{row.line["hsn_sac"] || "—"}</span>
                  <span
                    :if={row.line["hsn_description"]}
                    class="text-ink-subtle text-ui block truncate"
                    title={row.line["hsn_description"]}
                  >
                    {row.line["hsn_description"]}
                  </span>
                </div>
              </:col>
              <:col :let={row} label="Rate" align="right">
                <div :if={row.kind == :line}>
                  <span>{line_rate_label(row.line)}</span>
                  <span
                    :if={rate_candidate_label(row.line)}
                    class="text-ink-subtle text-ui block whitespace-nowrap"
                    title={rate_candidate_source(row.line)}
                  >
                    {rate_candidate_label(row.line)}
                  </span>
                </div>
              </:col>
              <:col :let={row} label="Taxable" align="right" class="whitespace-nowrap">
                <span>
                  {amount(
                    if row.kind == :total, do: row.totals.taxable, else: row.line["taxable_value"]
                  )}
                </span>
                <span
                  :if={row.kind == :line and taxable_basis_label(row.line)}
                  class="text-ink-subtle text-ui block"
                >
                  {taxable_basis_label(row.line)}
                </span>
              </:col>
              <:col :let={row} label="Extracted GST" align="right" class="whitespace-nowrap">
                <span :if={row.kind == :total}>{amount(row.totals.tax)}</span>
                <div :if={row.kind == :line}>
                  <% reading = line_tax_reading(row.line) %>
                  <span>{reading.total}</span>
                  <span :if={reading.split} class="text-ink-subtle text-ui block">
                    {reading.split}
                  </span>
                </div>
              </:col>
              <%!-- The tick is the outcome; its tooltip is the arithmetic in
                    longhand, for the reader who wants the claim spelled out. --%>
              <:col :let={row} label="Check" align="right">
                <span :if={row.verdict} class="inline-flex" title={row.verdict.claim}>
                  <.icon
                    name={if row.verdict.passed, do: "hero-check-mini", else: "hero-x-mark-mini"}
                    class={["size-4 shrink-0", (row.verdict.passed && "text-success") || "text-error"]}
                  />
                </span>
              </:col>
            </.data_table>
            <p id="gstr1-rate-validation-scope" class="mt-related text-ink-subtle text-ui">
              HSN/SAC existence, tax arithmetic, and imported taxable-goods rate candidates are checked independently. Exemptions and description-dependent conditions still require review.
            </p>
          </div>

          <%!-- Keyed the same way as the button that scrolls here. `flagged`
                always carries a `{source_id, field}` entry but only carries
                `{invoice_number, field}` for uniquely numbered invoices, so
                reading it by `pristine_inum` alone meant that on a
                duplicate-numbered invoice the "Correct extraction" button
                rendered, the hook found no target, and the click did nothing at
                all. --%>
          <div
            :if={
              Gstr1.correctable_fields(
                @flagged,
                @selected_invoice["id"] || @selected_invoice["pristine_inum"]
              ) != []
            }
            id="gstr1-corrections"
            class="space-y-related"
          >
            <div class="text-ink-subtle text-label font-semibold uppercase">
              Fields flagged for correction
            </div>
            <%= for field <- Gstr1.correctable_fields(@flagged, @selected_invoice["id"] || @selected_invoice["pristine_inum"]) do %>
              <%= if @correcting && @correcting.field == field do %>
                <.form
                  for={@correction_form}
                  id="gstr1-correction-form"
                  phx-submit="save_correct"
                  phx-target={@target}
                  class="flex items-end gap-2"
                >
                  <.input field={@correction_form[:field]} type="hidden" />
                  <div class="flex-1">
                    <.input field={@correction_form[:value]} type="text" label={field} />
                  </div>
                  <.button type="submit" variant="primary" size="sm">Save</.button>
                  <.button
                    type="button"
                    variant="ghost"
                    size="sm"
                    phx-click="cancel_correct"
                    phx-target={@target}
                  >Cancel</.button>
                </.form>
              <% else %>
                <div class="flex items-center justify-between gap-2">
                  <span class="text-ink-muted text-ui min-w-0 truncate font-mono">
                    {field} = {to_string(Gstr1.field_value(@selected_invoice, field))}
                  </span>
                  <.button
                    variant="ghost"
                    size="xs"
                    phx-click="start_correct"
                    phx-value-field={field}
                    phx-target={@target}
                  >Correct</.button>
                </div>
              <% end %>
            <% end %>
          </div>
        </div>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".InvoiceReview">
          export default {
            mounted() {
              this.onClick = (event) => {
                const trigger = event.target.closest("[data-review-target]")
                const dialog = this.el.closest("[role='dialog']")
                if (!trigger || !dialog || !dialog.contains(trigger)) return
                this.focusTarget(trigger.dataset.reviewTarget)
              }
              this.onKeydown = (event) => {
                const tag = event.target.tagName
                if (["INPUT", "TEXTAREA", "SELECT"].includes(tag) || event.target.isContentEditable) return
                const direction = event.key === "ArrowLeft" ? "previous" :
                  event.key === "ArrowRight" ? "next" : null
                const item = direction && this.el.dataset[direction]
                if (!item) return
                event.preventDefault()
                this.pushEventTo(this.el.dataset.eventTarget, "navigate-invoice-review", { direction })
              }
              window.addEventListener("click", this.onClick)
              window.addEventListener("keydown", this.onKeydown)
              if (this.el.dataset.initialFocus) {
                window.requestAnimationFrame(() => this.focusTarget(this.el.dataset.initialFocus))
              }
            },
            destroyed() {
              window.removeEventListener("click", this.onClick)
              window.removeEventListener("keydown", this.onKeydown)
              window.clearTimeout(this.focusTimer)
            },
            focusTarget(id) {
              const target = document.getElementById(id)
              if (!target) return
              target.scrollIntoView({ behavior: "smooth", block: "center" })
              if (this.focused) this.unfocus(this.focused)
              this.focused = target
              target.classList.add("ring-2", "ring-warning", "ring-inset")
              window.clearTimeout(this.focusTimer)
              this.focusTimer = window.setTimeout(() => this.unfocus(target), 1800)
            },
            unfocus(target) {
              target.classList.remove("ring-2", "ring-warning", "ring-inset")
              if (this.focused === target) this.focused = null
            }
          }
        </script>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :issue, :map, required: true
  attr :check, :any, default: nil
  attr :checks, :list, default: []
  attr :values, :any, default: nil
  attr :decisions, :map, required: true
  attr :can_correct, :boolean, default: false
  attr :r1_signoff, :any, default: nil
  attr :target, :any, required: true

  defp issue_card(assigns) do
    assigns =
      assigns
      |> assign(:decision, assigns.decisions[SalesWorkings.issue_key(assigns.issue)])
      |> assign(:mismatch, mismatch_reading(assigns.check))
      |> assign(:filed_effect, filed_effect(assigns.issue, assigns.values))
      |> assign(:proposal, Proposals.for_issue(assigns.issue, assigns.values, assigns.checks))

    ~H"""
    <div
      id={@id}
      class="bg-base-200/40 border-base-300 rounded-box scroll-mt-4 border p-3 transition-colors"
    >
      <.badge variant={
        if @issue["status"] == "resolved",
          do: "success",
          else: Helpers.severity_variant(@issue["level"])
      }>
        {issue_label(@issue["code"])}
      </.badge>
      <%!-- The engine's message names portal fields ("camt line-tax sum…"). The
            chip already translates that; the card body says the same thing. --%>
      <p class="mt-related text-body text-ink-muted">{issue_body(@issue)}</p>

      <%!-- The difference is the entire reason this card is open, so it is a
            term of the reading rather than subtraction left to the reader. --%>
      <dl :if={@mismatch} class="border-base-300 mt-block grid gap-2 border-y py-3 sm:grid-cols-3">
        <div>
          <dt class="text-ink-subtle text-label">{@mismatch.printed_label}</dt>
          <dd class="font-display text-base-content text-body mt-1 leading-none tabular-nums">
            {Helpers.rupees(@mismatch.printed)}
          </dd>
        </div>
        <div>
          <dt class="text-ink-subtle text-label">{@mismatch.extracted_label}</dt>
          <dd class="font-display text-base-content text-body mt-1 leading-none tabular-nums">
            {Helpers.rupees(@mismatch.extracted)}
          </dd>
        </div>
        <div>
          <dt class="text-ink-subtle text-label">Difference</dt>
          <dd class="font-display text-body text-error mt-1 leading-none tabular-nums">
            {Helpers.rupees(@mismatch.extracted - @mismatch.printed)}
          </dd>
        </div>
      </dl>

      <%!-- Nila takes a position instead of only asking. Three parts, never two:
            what it would do, what it observed to think so, and what that files.
            The basis is an observation about this document — never an inference
            about what the client or their supplier did. --%>
      <div
        :if={@proposal && @issue["status"] == "open"}
        id={"#{@id}-proposal"}
        class="border-base-300 mt-block rounded-box border p-3"
      >
        <div class="text-ink-subtle text-label font-semibold uppercase">Nila's read</div>
        <%!-- The action line used to sit here in prose, above buttons of equal
              weight, so the reviewer read a sentence and then matched it by eye
              to one of them. It is now the primary button's own label; what is
              left here is the reasoning behind it. --%>
        <p class="text-body text-ink-muted mt-1">{@proposal.basis}</p>
        <%!-- What accepting it does to the numbers. `Proposals.for_issue/3`
              returns a proposal only for the three arithmetic codes and only
              when the filed figures are known — which is exactly when
              `filed_effect/2` speaks — so every proposal that reaches this
              block has its money stated. A fallback for the other case was
              written and was unreachable; it is not kept as decoration. --%>
        <p :if={@filed_effect} class="mt-related text-body text-ink-subtle">{@filed_effect}</p>
      </div>

      <%!-- Neither figure above is filed. The return recomputes per rate bucket,
            so an action offering "use the line total" would name a number the
            engine cannot put in the JSON. --%>
      <p
        :if={@filed_effect && is_nil(@proposal)}
        id={"#{@id}-filed-effect"}
        class="mt-related text-body text-ink-subtle"
      >
        {@filed_effect}
      </p>

      <%!-- Settled by Nila, not by anyone here: an `info` check has already been
            explained and neither `required?` nor `reviewable?` reads it, so a
            button on it would change nothing when clicked. --%>
      <p
        :if={@issue["status"] == "open" and Issues.level(@issue) == "info"}
        class="mt-block text-ink-subtle text-ui flex items-center gap-1.5"
      >
        <.icon name="hero-check-mini" class="text-success size-4 shrink-0" />
        {settled_note(@issue)}
      </p>

      <div
        :if={
          @issue["status"] == "open" and is_nil(@r1_signoff) and
            Issues.gating?(@issue) and
            (not SalesWorkings.blocking?(@issue) or @can_correct)
        }
        class="mt-block flex flex-wrap gap-2"
      >
        <.button
          :if={not SalesWorkings.blocking?(@issue)}
          variant="primary"
          size="sm"
          phx-click="resolve-invoice-issue"
          phx-target={@target}
          phx-value-target={SalesWorkings.issue_key(@issue)}
          phx-value-decision={(@proposal && @proposal.decision) || "use_extracted_lines"}
        >
          {(@proposal && @proposal.action) || resolution_action(@issue)}
        </.button>
        <.button
          :if={@can_correct}
          type="button"
          variant="outline"
          size="sm"
          data-review-target="gstr1-corrections"
        >
          Correct extraction
        </.button>
      </div>

      <div :if={@issue["status"] == "resolved"} class="mt-block flex items-start gap-3">
        <.icon name="hero-check-circle" class="text-success mt-0.5 size-4 shrink-0" />
        <div class="min-w-0 flex-1">
          <p class="text-base-content text-ui font-medium">
            Resolved by {decision_maker(@decision)}
          </p>
          <p class="text-ink-muted text-ui">
            {decision_summary(@issue, @decision)} ·
            <.context_text>{decision_time(@decision)}</.context_text>
          </p>
        </div>
        <.button
          :if={is_nil(@r1_signoff)}
          variant="ghost"
          size="xs"
          phx-click="undo"
          phx-target={@target}
          phx-value-target={SalesWorkings.issue_key(@issue)}
        >
          Undo
        </.button>
      </div>
    </div>
    """
  end

  # Each extracted line, then the totals row that answers the question the eye
  # asks last: do these add up to what the bill printed? Verdicts are the
  # validation layer's, grouped onto the row whose numbers they judge — a line
  # with no judgeable arithmetic (all zeroes) simply carries no tick.
  defp read_rows(invoice, checks) do
    lines = List.wrap(invoice["line_items"])

    if lines == [] do
      []
    else
      rows =
        lines
        |> Enum.with_index(1)
        |> Enum.map(fn {line, index} ->
          %{
            kind: :line,
            dom_id: "gstr1-line-#{index}",
            line: line,
            verdict: verdict(Enum.filter(checks, &(&1["line"] == index)))
          }
        end)

      totals = Enum.filter(checks, &is_nil(&1["line"]))

      rows ++
        [
          %{
            kind: :total,
            dom_id: "gstr1-line-total",
            totals: Gstr1.extracted_totals(invoice),
            verdict: verdict(totals)
          }
        ]
    end
  end

  defp review_state([]), do: %{variant: "success", label: "Review complete"}

  defp review_state(open_issues) do
    if Enum.any?(open_issues, &Issues.gating?/1) do
      %{variant: "error", label: "Filing blocked"}
    else
      %{variant: "warning", label: "Review note"}
    end
  end

  # Counts what the register counts. This used to count every open issue,
  # including the ones Nila settled itself, so the modal said "3 unresolved
  # checks" beside a register row reading "1".
  defp unresolved_label(open_issues) do
    case Enum.filter(open_issues, &Issues.gating?/1) do
      [] -> "Nothing left to answer"
      [_issue] -> "1 to answer"
      gating -> "#{length(gating)} to answer"
    end
  end

  defp settled_note(%{"code" => "rounding_variance"} = issue) do
    "#{issue_chip_label(issue)} — explained by per-line rounding, accepted."
  end

  defp settled_note(issue), do: "#{issue_chip_label(issue)} — checked and accepted."

  # The engine's message is written for the engine's own fields. `issue_chip_label`
  # already translates the rounding family; anything it does not translate is
  # already in the reviewer's language and passes through.
  defp issue_body(%{"code" => "rounding_variance", "message" => message} = issue) do
    case Regex.run(~r/by (-?[\d.]+),/, message) do
      [_, delta] -> "#{issue_chip_label(issue)} of #{Helpers.rupees(parse_money(delta))}."
      _ -> issue_chip_label(issue)
    end
  end

  defp issue_body(%{"code" => "bucket_tax_mismatch", "message" => message}) do
    case Regex.run(~r/differs from bucket taxable × ([\d.]+)% .* by (-?[\d.]+),/, message) do
      [_, rate, delta] ->
        "The tax on these lines is #{Helpers.rupees(parse_money(delta))} away from " <>
          "#{Helpers.percent(parse_money(rate))} of what they are taxable on."

      _ ->
        message
    end
  end

  # The totals agree, so nothing else on the page shows a consequence. Say what
  # it is: the return can only file one head, so whichever the reviewer decides
  # is wrong was collected and will not be remitted under the head the buyer
  # holds paper for.
  defp issue_body(%{"code" => "mixed_tax_heads", "message" => message}) do
    message <>
      ". The return files one head for the whole invoice, so the other is dropped " <>
      "— the buyer's 2B will not match the bill they hold."
  end

  defp issue_body(issue), do: issue["message"]

  defp parse_money(text) do
    {value, _rest} = Float.parse(text)
    value
  end

  defp issue_chip_label(%{"code" => "rounding_variance", "message" => message}) do
    cond do
      String.starts_with?(message, "camt ") -> "CGST rounding difference"
      String.starts_with?(message, "samt ") -> "SGST rounding difference"
      String.starts_with?(message, "iamt ") -> "IGST rounding difference"
      true -> issue_label("rounding_variance")
    end
  end

  defp issue_chip_label(issue), do: issue_label(issue["code"])

  defp issue_dom_id(issue) do
    location =
      case issue_line(issue) do
        nil -> Integer.to_string(:erlang.phash2(issue["message"]))
        line -> "line-#{line}"
      end

    "gstr1-issue-#{issue["code"]}-#{location}"
  end

  defp issue_focus_target(%{"code" => code})
       when code in ~w(printed_taxable_mismatch printed_tax_mismatch grand_total_mismatch),
       do: "gstr1-line-total"

  defp issue_focus_target(%{"fields" => fields} = issue) do
    cond do
      line = issue_line(issue) -> "gstr1-line-#{line}"
      "buyer_gstin" in List.wrap(fields) -> "gstr1-review-buyer"
      true -> issue_dom_id(issue)
    end
  end

  defp issue_line(issue) do
    Enum.find_value(List.wrap(issue["fields"]), fn field ->
      case Regex.run(~r/^line_items\[(\d+)\]/, field) do
        [_, index] -> String.to_integer(index) + 1
        _ -> nil
      end
    end)
  end

  defp unclaimed(issue, claimed) do
    if MapSet.member?(claimed, issue), do: nil, else: issue
  end

  defp issue_for_check(issues, check) do
    Enum.find(issues, fn issue ->
      issue["code"] == check["code"] and
        (issue["fields"] == check["fields"] or covers_line?(issue, check))
    end)
  end

  # `lines` is written by the collapsing generators; an issue that never merged
  # does not carry it, and falls back to the exact-fields match above.
  defp covers_line?(%{"lines" => lines}, %{"line" => line})
       when is_list(lines) and not is_nil(line),
       do: line in lines

  defp covers_line?(_issue, _check), do: false

  defp issue_correctable?(issue, flagged, invoice) do
    candidates = Gstr1.correctable_fields(flagged, invoice["id"] || invoice["pristine_inum"])

    Enum.any?(List.wrap(issue["fields"]), fn issue_field ->
      Enum.any?(candidates, fn candidate ->
        candidate == issue_field or String.starts_with?(candidate, issue_field <> "[") or
          String.starts_with?(candidate, issue_field <> ".")
      end)
    end)
  end

  defp mismatch_reading(%{"code" => code, "operands" => operands})
       when code in ~w(printed_taxable_mismatch printed_tax_mismatch grand_total_mismatch) do
    %{
      printed_label: printed_total_label(code),
      printed: operands["printed"],
      extracted_label: extracted_total_label(code),
      extracted: operands["derived"]
    }
  end

  defp mismatch_reading(_check), do: nil

  defp printed_total_label("printed_taxable_mismatch"), do: "Printed taxable total"
  defp printed_total_label("printed_tax_mismatch"), do: "Printed tax total"
  defp printed_total_label("grand_total_mismatch"), do: "Printed bill total"

  defp extracted_total_label("printed_taxable_mismatch"), do: "Sum of extracted lines"
  defp extracted_total_label("printed_tax_mismatch"), do: "Sum of extracted line taxes"
  defp extracted_total_label("grand_total_mismatch"), do: "Sum of extracted lines"

  # The action says which figure reaches the filing, because that is the whole
  # consequence of the click. It cannot name the line total: `derive_invoice/2`
  # recomputes tax per rate bucket, so the sum of the extracted lines is never
  # what gets filed. "Accept" is honest about electing a basis rather than
  # picking a number.
  defp resolution_action(%{"code" => code})
       when code in ~w(printed_taxable_mismatch printed_tax_mismatch grand_total_mismatch),
       do: "Accept the extracted lines"

  defp resolution_action(_issue), do: "Keep extracted value"

  # What accepting actually files, in the figure the portal receives. Silent
  # when the invoice is not in the return (excluded, or held out by a blocker)
  # and when the recomputation lands on the extracted sum exactly — there is no
  # second number to warn about.
  defp filed_effect(%{"code" => code}, %{filed: filed} = values)
       when code in ~w(printed_taxable_mismatch printed_tax_mismatch grand_total_mismatch) and
              not is_nil(filed) do
    %{tax: tax_delta, taxable: taxable_delta} = values.extracted_vs_filed
    files = "Files #{Helpers.rupees(filed.tax)} tax on #{Helpers.rupees(filed.taxable)} taxable"

    if tax_delta == 0 and taxable_delta == 0 do
      files <> "."
    else
      files <>
        " — the return aggregates and rounds each rate bucket once, so it differs from the " <>
        "line sum above by #{Helpers.rupees(abs(tax_delta))}."
    end
  end

  defp filed_effect(_issue, _values), do: nil

  defp decision_maker(%{decided_by: %{name: name}}) when is_binary(name), do: name
  defp decision_maker(_decision), do: "a reviewer"

  defp decision_summary(
         %{"code" => code},
         %{payload: %{"decision" => "use_extracted_lines"}}
       )
       when code in ~w(printed_taxable_mismatch printed_tax_mismatch grand_total_mismatch),
       do: "Accepted extracted line total"

  defp decision_summary(_issue, %{payload: %{"decision" => "use_extracted_lines"}}),
    do: "Kept extracted value"

  defp decision_summary(_issue, _decision), do: "Confirmed against original"

  defp decision_time(%{inserted_at: inserted_at}),
    do: Nila.Formatters.format_display_datetime_with_time(inserted_at)

  defp decision_time(_decision), do: "Decision recorded"

  defp verdict([]), do: nil

  defp verdict(checks) do
    %{
      passed: Enum.all?(checks, & &1["passed"]),
      claim: Enum.map_join(checks, " · ", &check_claim/1)
    }
  end

  defp check_key(check), do: {check["code"], check["fields"]}

  # One line per verified claim, in the arithmetic the bill itself printed.
  defp check_claim(%{"code" => "line_arithmetic"} = check) do
    ops = check["operands"]

    "L#{check["line"]}: #{amount(ops["taxable"])} × #{percent(ops["rate"])} = #{amount(ops["actual"])}"
  end

  defp check_claim(%{"code" => "cgst_sgst_unequal"} = check) do
    ops = check["operands"]
    "L#{check["line"]}: CGST #{amount(ops["cgst"])} = SGST #{amount(ops["sgst"])}"
  end

  defp check_claim(%{"code" => code} = check) do
    ops = check["operands"]
    "#{total_label(code)}: lines #{amount(ops["derived"])} = printed #{amount(ops["printed"])}"
  end

  defp total_label("printed_taxable_mismatch"), do: "taxable"
  defp total_label("printed_tax_mismatch"), do: "tax"
  defp total_label("grand_total_mismatch"), do: "grand total"

  defp sales_review_path(client, period, source_id, focus) do
    query = URI.encode_query(%{"item" => source_id, "scope" => "needs_you", "focus" => focus})
    "/gst/#{client.id}/#{period}/review/sales?" <> query
  end

  defp amount(value), do: Helpers.amount(value)
  defp percent(rate), do: Helpers.percent(rate)

  defp taxable_basis_label(%{"taxable_value_basis" => "printed_taxable_value"}),
    do: "Printed taxable value"

  defp taxable_basis_label(%{
         "taxable_value_basis" => "line_amount_plus_tax_equals_total"
       }),
       do: "Value + tax = total"

  defp taxable_basis_label(%{
         "taxable_value_basis" => "line_amount_times_rate_equals_tax"
       }),
       do: "Value × rate = tax"

  defp taxable_basis_label(%{"taxable_value_basis" => "printed_exclusive_line_amount"}),
    do: "Printed amount · tax extra"

  defp taxable_basis_label(%{
         "taxable_value_basis" => "derived_from_inclusive_line_amount"
       }),
       do: "Derived from tax-inclusive amount"

  defp taxable_basis_label(%{"taxable_value_basis" => "corrected"}),
    do: "Reviewer corrected"

  defp taxable_basis_label(%{"taxable_value" => nil}), do: "Not determined"
  defp taxable_basis_label(_line), do: nil

  defp line_rate_label(line) do
    rate =
      [line["cgst_rate"], line["sgst_rate"], line["igst_rate"]]
      |> Enum.map(&if(is_number(&1), do: &1, else: 0))
      |> Enum.sum()

    if rate == 0, do: "—", else: percent(rate)
  end

  defp rate_candidate_label(line) do
    case get_in(line, ["rate_validation", "candidate_rates"]) do
      [_ | _] = rates -> "Candidate " <> Enum.map_join(rates, "/", &percent/1)
      _ -> nil
    end
  end

  defp rate_candidate_source(line) do
    case get_in(line, ["rate_validation", "candidates"]) do
      [candidate | _] ->
        "#{candidate["notification_number"]}, Schedule #{candidate["schedule"]}, " <>
          "entry #{candidate["serial_number"]}"

      _ ->
        nil
    end
  end

  # The total leads and the split sits under it, always visible. `2,166.89 +
  # 2,166.89` on one line was the widest cell in a table whose pane only scrolls
  # vertically, and hover-only accounting evidence is inaccessible and easy to
  # miss — so the split is persistent secondary text, not a tooltip.
  defp line_tax_reading(line) do
    cgst = line["cgst_amount"]
    sgst = line["sgst_amount"]

    cond do
      is_number(line["igst_amount"]) ->
        %{total: amount(line["igst_amount"]), split: "IGST"}

      is_number(cgst) or is_number(sgst) ->
        %{
          total: amount((cgst || 0) + (sgst || 0)),
          split: "CGST #{amount(cgst)} · SGST #{amount(sgst)}"
        }

      true ->
        %{total: "—", split: nil}
    end
  end
end
