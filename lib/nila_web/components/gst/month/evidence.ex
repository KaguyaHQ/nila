defmodule NilaWeb.Components.Gst.Month.Evidence do
  use NilaWeb, :html

  @moduledoc "Evidence and correction modals for the GST month workbench."

  alias Nila.Gst.Issues
  alias Nila.Gst.Sales.Gstr1
  alias Nila.Gst.Sales.Workings, as: SalesWorkings
  alias NilaWeb.Components.Gst.Month.Helpers

  attr :show_chase_history, :boolean, required: true
  attr :client, :map, required: true
  attr :period, :string, required: true
  attr :asks, :list, required: true
  attr :selected_row, :any, default: nil
  attr :selected_invoice, :any, default: nil
  attr :source_invoices, :list, default: []
  attr :duplicate_issue, :any, default: nil
  attr :focused_issue, :string, default: nil
  attr :show_completeness_override, :boolean, default: false
  attr :completeness_override_form, :any, default: nil
  attr :issues_by_invoice, :map, required: true
  attr :decisions, :map, default: %{}
  attr :review_navigation, :map, default: %{previous: nil, next: nil}
  attr :r1_signoff, :any, default: nil
  attr :flagged, :any, required: true
  attr :correcting, :any, default: nil

  def evidence_modals(assigns) do
    ~H"""
    <.modal
      :if={@show_chase_history}
      id="month-chase-history-modal"
      title={"Asked #{@client.name} · #{period_label(@period)}"}
      on_close="close-chase-history"
      class="max-w-2xl"
    >
      <.chase_history asks={@asks} />
    </.modal>

    <.modal
      :if={@selected_row}
      id="gst-evidence-modal"
      title={evidence_title(@selected_row)}
      on_close="close-evidence"
      class="max-w-4xl"
    >
      <div class="gap-block grid lg:grid-cols-[1fr_20rem]">
        <div id="gst-evidence-images" class="space-y-3">
          <img
            :for={url <- @selected_row["image_urls"]}
            src={url}
            alt="Scanned bill"
            class="border-base-300 rounded-box w-full border"
          />
          <div
            :if={@selected_row["image_urls"] == []}
            class="border-base-300 rounded-box text-body text-ink-muted flex h-40 items-center justify-center border border-dashed"
          >
            No scanned bill — this line appears in GSTR-2B only.
          </div>
        </div>

        <div id="gst-evidence-why" class="space-y-block">
          <div>
            <div class="text-ink-subtle text-label font-semibold uppercase">Vendor</div>
            <div class="text-base-content text-body mt-1 font-medium">
              {@selected_row["vendor_name"]}
            </div>
            <div :if={@selected_row["vendor_gstin"]} class="text-ink-subtle text-meta mt-0.5">
              {@selected_row["vendor_gstin"]}
            </div>
          </div>
          <div :if={@selected_row["recon_note"]}>
            <div class="text-ink-subtle text-label font-semibold uppercase">Recon note</div>
            <p class="text-base-content text-body mt-1">{@selected_row["recon_note"]}</p>
          </div>
          <div :if={@selected_row["next_action"]}>
            <div class="text-ink-subtle text-label font-semibold uppercase">Next action</div>
            <p class="text-base-content text-body mt-1">{@selected_row["next_action"]}</p>
          </div>
          <div :if={@selected_row["flags"] not in [nil, []]} class="space-y-related">
            <div class="text-ink-subtle text-label font-semibold uppercase">Flags</div>
            <div
              :for={flag <- @selected_row["flags"]}
              class="bg-base-200/40 border-base-300 rounded-box border p-3"
            >
              <.badge variant={if flag["severity"] == "error", do: "error", else: "warning"}>
                {issue_label(flag["code"])}
              </.badge>
              <p class="mt-related text-body text-ink-muted">{flag["reason"]}</p>
            </div>
          </div>
        </div>
      </div>
    </.modal>

    <.duplicate_review_modal
      :if={@duplicate_issue}
      issue={@duplicate_issue}
      invoices={@source_invoices}
    />

    <.modal
      :if={@show_completeness_override}
      id="gstr1-completeness-override-modal"
      title="Record client confirmation"
      on_close="close-completeness-override"
      class="max-w-xl"
    >
      <div class="space-y-block">
        <section class="space-y-related">
          <h3 class="text-base-content text-body font-semibold">Ask the client on WhatsApp</h3>
          <p class="text-body text-ink-muted">
            Send a period-specific Yes/No request. Only the client phone on record can confirm it.
          </p>
          <.button
            :if={@client.chase_channel == "whatsapp" and is_binary(@client.phone)}
            id="gstr1-send-completeness-request"
            variant="primary"
            size="sm"
            phx-click="send-completeness-request"
          >
            Send WhatsApp confirmation request
          </.button>
          <p
            :if={@client.chase_channel != "whatsapp" or is_nil(@client.phone)}
            class="text-ui text-warning"
          >
            Add a WhatsApp phone and select WhatsApp as this client’s chase channel first.
          </p>
        </section>

        <div class="border-base-300 border-t pt-4">
          <h3 class="text-base-content text-body font-semibold">Senior override</h3>
        </div>

        <.form
          for={@completeness_override_form}
          id="gstr1-completeness-override-form"
          phx-submit="save-completeness-override"
          class="space-y-block"
        >
          <p class="text-body text-ink-muted">
            Use this only when the firm has independent evidence that every sales invoice, credit/debit note, and cancellation detail for the period was supplied.
          </p>
          <.input
            field={@completeness_override_form[:reason]}
            type="textarea"
            label="Reason for override"
            placeholder="State the evidence relied on"
          />
          <div class="flex justify-end gap-2">
            <.button type="button" variant="ghost" phx-click="close-completeness-override">
              Cancel
            </.button>
            <.button type="submit" variant="primary">Record override</.button>
          </div>
        </.form>
      </div>
    </.modal>

    <.invoice_modal
      :if={@selected_invoice}
      selected_invoice={@selected_invoice}
      issues_by_invoice={@issues_by_invoice}
      focused_issue={@focused_issue}
      decisions={@decisions}
      review_navigation={@review_navigation}
      r1_signoff={@r1_signoff}
      flagged={@flagged}
      correcting={@correcting}
    />
    """
  end

  attr :issue, :map, required: true
  attr :invoices, :list, required: true

  defp duplicate_review_modal(assigns) do
    members = Enum.filter(assigns.invoices, &(&1["id"] in assigns.issue["source_ids"]))
    assigns = assign(assigns, :members, members)

    ~H"""
    <.modal
      id="gstr1-duplicate-review-modal"
      title={"Duplicate invoice #{@issue["invoice"]}"}
      on_close="close-duplicate-review"
      class="max-w-6xl"
      scrim_class="bg-scrim/70"
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
                phx-click="review-sales-issue"
                phx-value-source={invoice["id"]}
                phx-value-target={SalesWorkings.issue_key(@issue)}
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
  defp invoice_modal(assigns) do
    checks = Gstr1.invoice_checks(assigns.selected_invoice)
    issues = Helpers.invoice_issues(assigns.issues_by_invoice, assigns.selected_invoice)

    check_issues =
      checks
      |> Enum.reject(& &1["passed"])
      |> Map.new(fn check ->
        {check_key(check),
         Enum.find(issues, &(&1["code"] == check["code"] and &1["fields"] == check["fields"]))}
      end)

    in_place = check_issues |> Map.values() |> Enum.reject(&is_nil/1)

    open_issues = Enum.filter(issues, &(&1["status"] == "open"))
    focused_issue = Enum.find(issues, &(SalesWorkings.issue_key(&1) == assigns.focused_issue))

    assigns =
      assigns
      |> assign(:failed_checks, Enum.reject(checks, & &1["passed"]))
      |> assign(:check_issues, check_issues)
      |> assign(:other_issues, issues -- in_place)
      |> assign(:open_issues, open_issues)
      |> assign(:initial_focus, focused_issue && issue_focus_target(focused_issue))
      |> assign(:review_state, review_state(open_issues))
      |> assign(:read_rows, read_rows(assigns.selected_invoice, checks))

    ~H"""
    <.modal
      id="gstr1-evidence-modal"
      title={@selected_invoice["invoice_number"] || "Invoice"}
      on_close="close-invoice-review"
      scrim_class="bg-scrim/70"
      class="h-[90vh] max-w-384"
    >
      <:header :let={title_id}>
        <div id="gstr1-review-header" class="space-y-related">
          <div class="grid items-center gap-3 lg:grid-cols-[1fr_auto_1fr]">
            <button
              type="button"
              id="gstr1-review-previous"
              phx-click={@review_navigation.previous && "navigate-invoice-review"}
              phx-value-inum={@review_navigation.previous}
              disabled={is_nil(@review_navigation.previous)}
              class="hover:text-ink text-ink-subtle text-ui justify-self-start transition disabled:opacity-30"
            >
              ← Previous flagged invoice
            </button>
            <div class="flex flex-wrap items-center justify-center gap-2 text-center">
              <h3 id={title_id} class="text-base-content text-body font-semibold">
                {@selected_invoice["invoice_number"] || "Invoice"}
              </h3>
              <span class="text-ink-subtle text-ui">{unresolved_label(@open_issues)}</span>
              <.badge variant={@review_state.variant}>{@review_state.label}</.badge>
            </div>
            <button
              type="button"
              id="gstr1-review-next"
              phx-click={@review_navigation.next && "navigate-invoice-review"}
              phx-value-inum={@review_navigation.next}
              disabled={is_nil(@review_navigation.next)}
              class="hover:text-ink text-ink-subtle text-ui justify-self-end transition disabled:opacity-30"
            >
              Next flagged invoice →
            </button>
          </div>
          <div :if={@open_issues != []} class="flex flex-wrap justify-center gap-2">
            <button
              :for={{issue, index} <- Enum.with_index(@open_issues, 1)}
              type="button"
              data-review-target={issue_focus_target(issue)}
              class="bg-warning/10 hover:bg-warning/20 rounded-field text-base-content text-meta flex items-center gap-1.5 px-2 py-1 font-medium transition-colors"
            >
              <span class="bg-warning/15 rounded-full px-1.5 tabular-nums">{index}</span>
              {issue_chip_label(issue)}
            </button>
          </div>
        </div>
      </:header>

      <div
        id="gstr1-review-workflow"
        phx-hook=".InvoiceReview"
        data-previous={@review_navigation.previous}
        data-next={@review_navigation.next}
        data-initial-focus={@initial_focus}
        class="gap-block grid h-full min-h-0 lg:grid-cols-[minmax(0,1.15fr)_minmax(0,1fr)]"
      >
        <div id="gstr1-evidence-images" class="min-h-0 space-y-3 overflow-y-auto">
          <p class="text-ink-subtle text-label font-semibold uppercase">Original document</p>
          <img
            :for={url <- @selected_invoice["image_urls"]}
            src={url}
            alt="Scanned sales bill"
            class="border-base-300 rounded-box w-full border"
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
            <div class="text-ink-subtle text-meta mt-0.5 font-mono">
              {@selected_invoice["buyer_gstin"] || "—"}
            </div>
          </div>

          <%!-- The decision leads. It used to sit fourth, below a twelve-row line
                table and below the fold — the reader scrolled past the evidence
                to find the question the evidence answers. Sticky, so the figures
                stay on screen while the lines beneath them are read. --%>
          <div
            :if={@failed_checks != [] or @other_issues != []}
            id="gstr1-decisions"
            class="bg-base-100 space-y-related sticky top-0 z-10 pb-3"
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
                  decisions={@decisions}
                  can_correct={
                    issue_correctable?(@check_issues[check_key(check)], @flagged, @selected_invoice)
                  }
                  r1_signoff={@r1_signoff}
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
                decisions={@decisions}
                can_correct={issue_correctable?(issue, @flagged, @selected_invoice)}
                r1_signoff={@r1_signoff}
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
                    class="text-ink-subtle text-meta block truncate"
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
                    class="text-ink-subtle text-meta block whitespace-nowrap"
                    title={rate_candidate_source(row.line)}
                  >
                    {rate_candidate_label(row.line)}
                  </span>
                </div>
              </:col>
              <:col :let={row} label="Taxable" align="right" class="whitespace-nowrap">
                {amount(
                  if row.kind == :total, do: row.totals.taxable, else: row.line["taxable_value"]
                )}
              </:col>
              <:col :let={row} label="Extracted tax" align="right" class="whitespace-nowrap">
                <span :if={row.kind == :total}>{amount(row.totals.tax)}</span>
                <div :if={row.kind == :line}>
                  <% reading = line_tax_reading(row.line) %>
                  <span>{reading.total}</span>
                  <span :if={reading.split} class="text-ink-subtle text-meta block">
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
            <p id="gstr1-rate-validation-scope" class="mt-related text-ink-subtle text-meta">
              HSN/SAC existence, tax arithmetic, and imported taxable-goods rate candidates are checked independently. Exemptions and description-dependent conditions still require review.
            </p>
          </div>

          <div
            :if={Gstr1.correctable_fields(@flagged, @selected_invoice["pristine_inum"]) != []}
            id="gstr1-corrections"
            class="space-y-related"
          >
            <div class="text-ink-subtle text-label font-semibold uppercase">
              Fields flagged for correction
            </div>
            <%= for field <- Gstr1.correctable_fields(@flagged, @selected_invoice["pristine_inum"]) do %>
              <%= if @correcting && @correcting.field == field do %>
                <form phx-submit="save_correct" class="flex items-end gap-2">
                  <.input type="hidden" name="field" id="gstr1-correct-field" value={field} />
                  <div class="flex-1">
                    <.input
                      type="text"
                      name="value"
                      value={@correcting.value}
                      label={field}
                      id="gstr1-correct-value"
                    />
                  </div>
                  <.button type="submit" variant="primary" size="sm">Save</.button>
                  <.button type="button" variant="ghost" size="sm" phx-click="cancel_correct">Cancel</.button>
                </form>
              <% else %>
                <div class="flex items-center justify-between gap-2">
                  <span class="text-ink-muted text-ui min-w-0 truncate font-mono">
                    {field} = {to_string(Gstr1.field_value(@selected_invoice, field))}
                  </span>
                  <.button variant="ghost" size="xs" phx-click="start_correct" phx-value-field={field}>
                    Correct
                  </.button>
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
                const inum = event.key === "ArrowLeft" ? this.el.dataset.previous :
                  event.key === "ArrowRight" ? this.el.dataset.next : null
                if (!inum) return
                event.preventDefault()
                this.pushEvent("navigate-invoice-review", { inum })
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
    </.modal>
    """
  end

  attr :id, :string, required: true
  attr :issue, :map, required: true
  attr :check, :any, default: nil
  attr :decisions, :map, required: true
  attr :can_correct, :boolean, default: false
  attr :r1_signoff, :any, default: nil

  defp issue_card(assigns) do
    assigns =
      assigns
      |> assign(:decision, assigns.decisions[SalesWorkings.issue_key(assigns.issue)])
      |> assign(:mismatch, mismatch_reading(assigns.check))

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
          <dt class="text-ink-subtle text-meta">{@mismatch.printed_label}</dt>
          <dd class="font-display text-base-content text-body mt-1 leading-none tabular-nums">
            {Helpers.rupees(@mismatch.printed)}
          </dd>
        </div>
        <div>
          <dt class="text-ink-subtle text-meta">{@mismatch.extracted_label}</dt>
          <dd class="font-display text-base-content text-body mt-1 leading-none tabular-nums">
            {Helpers.rupees(@mismatch.extracted)}
          </dd>
        </div>
        <div>
          <dt class="text-ink-subtle text-meta">Difference</dt>
          <dd class="font-display text-body text-error mt-1 leading-none tabular-nums">
            {Helpers.rupees(@mismatch.extracted - @mismatch.printed)}
          </dd>
        </div>
      </dl>

      <%!-- Settled by Nila, not by anyone here: an `info` check has already been
            explained and neither `required?` nor `reviewable?` reads it, so a
            button on it would change nothing when clicked. --%>
      <p
        :if={@issue["status"] == "open" and Issues.level(@issue) == "info"}
        class="mt-block text-ink-subtle text-meta flex items-center gap-1.5"
      >
        <.icon name="hero-check-mini" class="text-success size-4 shrink-0" />
        {settled_note(@issue)}
      </p>

      <div
        :if={
          @issue["status"] == "open" and is_nil(@r1_signoff) and
            Issues.gating?(@issue) and not SalesWorkings.blocking?(@issue)
        }
        class="mt-block flex flex-wrap gap-2"
      >
        <.button
          variant="primary"
          size="sm"
          phx-click="resolve-invoice-issue"
          phx-value-target={SalesWorkings.issue_key(@issue)}
          phx-value-decision="use_extracted_lines"
        >
          {resolution_action(@issue)}
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
          <p class="text-ink-subtle text-meta">
            {decision_summary(@issue, @decision)} · {decision_time(@decision)}
          </p>
        </div>
        <.button
          :if={is_nil(@r1_signoff)}
          variant="ghost"
          size="xs"
          phx-click="undo"
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
  # consequence of the click.
  defp resolution_action(%{"code" => code})
       when code in ~w(printed_taxable_mismatch printed_tax_mismatch grand_total_mismatch),
       do: "File the extracted lines"

  defp resolution_action(_issue), do: "Keep extracted value"

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

  defp amount(value), do: Helpers.amount(value)
  defp percent(rate), do: Helpers.percent(rate)

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

  defp evidence_title(row) do
    [row["invoice_number"], row["vendor_name"]]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
    |> case do
      "" -> "Evidence"
      title -> title
    end
  end
end
