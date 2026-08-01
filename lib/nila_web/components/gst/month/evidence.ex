defmodule NilaWeb.Components.Gst.Month.Evidence do
  use NilaWeb, :html

  @moduledoc "Evidence and correction modals for the GST month workbench."

  alias Nila.Gst.Sales.Gstr1
  alias Nila.Gst.Sales.Workings, as: SalesWorkings
  alias NilaWeb.Components.Gst.Month.Helpers

  attr :show_chase_history, :boolean, required: true
  attr :client, :map, required: true
  attr :period, :string, required: true
  attr :asks, :list, required: true
  attr :selected_row, :any, default: nil
  attr :selected_invoice, :any, default: nil
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
            <div :if={@selected_row["vendor_gstin"]} class="text-fine text-ink-subtle mt-0.5">
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

    <.invoice_modal
      :if={@selected_invoice}
      selected_invoice={@selected_invoice}
      issues_by_invoice={@issues_by_invoice}
      decisions={@decisions}
      review_navigation={@review_navigation}
      r1_signoff={@r1_signoff}
      flagged={@flagged}
      correcting={@correcting}
    />
    """
  end

  attr :selected_invoice, :map, required: true
  attr :issues_by_invoice, :map, required: true
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

    assigns =
      assigns
      |> assign(:failed_checks, Enum.reject(checks, & &1["passed"]))
      |> assign(:check_issues, check_issues)
      |> assign(:other_issues, issues -- in_place)
      |> assign(:open_issues, open_issues)
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
              class="hover:text-ink text-ink-subtle text-small justify-self-start transition disabled:opacity-30"
            >
              ← Previous flagged invoice
            </button>
            <div class="flex flex-wrap items-center justify-center gap-2 text-center">
              <h3 id={title_id} class="text-base-content text-body font-semibold">
                {@selected_invoice["invoice_number"] || "Invoice"}
              </h3>
              <span class="text-ink-subtle text-small">{unresolved_label(@open_issues)}</span>
              <.badge variant={@review_state.variant}>{@review_state.label}</.badge>
            </div>
            <button
              type="button"
              id="gstr1-review-next"
              phx-click={@review_navigation.next && "navigate-invoice-review"}
              phx-value-inum={@review_navigation.next}
              disabled={is_nil(@review_navigation.next)}
              class="hover:text-ink text-ink-subtle text-small justify-self-end transition disabled:opacity-30"
            >
              Next flagged invoice →
            </button>
          </div>
          <div :if={@open_issues != []} class="flex flex-wrap justify-center gap-2">
            <button
              :for={{issue, index} <- Enum.with_index(@open_issues, 1)}
              type="button"
              data-review-target={issue_focus_target(issue)}
              class="bg-warning/10 hover:bg-warning/20 rounded-field text-base-content text-fine flex items-center gap-1.5 px-2 py-1 font-medium transition-colors"
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
            <div class="text-fine text-ink-subtle mt-0.5 font-mono">
              {@selected_invoice["buyer_gstin"] || "—"}
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
                    class="text-fine text-ink-subtle block truncate"
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
                    class="text-fine text-ink-subtle block whitespace-nowrap"
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
              <:col :let={row} label="Tax" align="right" class="whitespace-nowrap">
                <span :if={row.kind == :total}>{amount(row.totals.tax)}</span>
                <span :if={row.kind == :line}>{line_tax_label(row.line)}</span>
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
            <p id="gstr1-rate-validation-scope" class="mt-related text-fine text-ink-subtle">
              HSN/SAC existence, tax arithmetic, and imported taxable-goods rate candidates are checked independently. Exemptions and description-dependent conditions still require review.
            </p>
          </div>

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
                  <span class="text-ink-muted text-small min-w-0 truncate font-mono">
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
                const target = document.getElementById(trigger.dataset.reviewTarget)
                if (!target) return
                target.scrollIntoView({ behavior: "smooth", block: "center" })
                if (this.focused) this.unfocus(this.focused)
                this.focused = target
                target.classList.add("ring-2", "ring-warning", "ring-inset")
                window.clearTimeout(this.focusTimer)
                this.focusTimer = window.setTimeout(() => this.unfocus(target), 1800)
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
            },
            destroyed() {
              window.removeEventListener("click", this.onClick)
              window.removeEventListener("keydown", this.onKeydown)
              window.clearTimeout(this.focusTimer)
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
      <p class="mt-related text-body text-ink-muted">{@issue["message"]}</p>

      <dl :if={@mismatch} class="border-base-300 mt-block grid gap-2 border-y py-3 sm:grid-cols-2">
        <div>
          <dt class="text-fine text-ink-subtle">{@mismatch.printed_label}</dt>
          <dd class="font-display text-base-content text-body mt-1 leading-none tabular-nums">
            {Helpers.rupees(@mismatch.printed)}
          </dd>
        </div>
        <div>
          <dt class="text-fine text-ink-subtle">{@mismatch.extracted_label}</dt>
          <dd class="font-display text-base-content text-body mt-1 leading-none tabular-nums">
            {Helpers.rupees(@mismatch.extracted)}
          </dd>
        </div>
      </dl>

      <div
        :if={
          @issue["status"] == "open" and is_nil(@r1_signoff) and
            not SalesWorkings.blocking?(@issue)
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
          <p class="text-base-content text-small font-medium">
            Resolved by {decision_maker(@decision)}
          </p>
          <p class="text-fine text-ink-subtle">
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
    if Enum.any?(open_issues, &(&1["level"] != "info")) do
      %{variant: "error", label: "Filing blocked"}
    else
      %{variant: "warning", label: "Review note"}
    end
  end

  defp unresolved_label([]), do: "No unresolved checks"
  defp unresolved_label([_issue]), do: "1 unresolved check"
  defp unresolved_label(issues), do: "#{length(issues)} unresolved checks"

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
    candidates = Gstr1.correctable_fields(flagged, invoice["pristine_inum"])

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

  defp extracted_total_label("printed_taxable_mismatch"), do: "Extracted line taxable"
  defp extracted_total_label("printed_tax_mismatch"), do: "Extracted line tax"
  defp extracted_total_label("grand_total_mismatch"), do: "Extracted lines total"

  defp resolution_action(%{"code" => code})
       when code in ~w(printed_taxable_mismatch printed_tax_mismatch grand_total_mismatch),
       do: "Use extracted lines"

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

  # The split is shown as the bill prints it — two halves or one IGST — so the
  # reader compares figure to figure, not a sum they'd have to do in their head.
  defp line_tax_label(line) do
    cond do
      is_number(line["igst_amount"]) ->
        amount(line["igst_amount"])

      is_number(line["cgst_amount"]) or is_number(line["sgst_amount"]) ->
        "#{amount(line["cgst_amount"])} + #{amount(line["sgst_amount"])}"

      true ->
        "—"
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
