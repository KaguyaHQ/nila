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
      <div class="grid gap-5 lg:grid-cols-[1fr_20rem]">
        <div id="gst-evidence-images" class="space-y-3">
          <img
            :for={url <- @selected_row["image_urls"]}
            src={url}
            alt="Scanned bill"
            class="border-base-300 rounded-box w-full border"
          />
          <div
            :if={@selected_row["image_urls"] == []}
            class="border-base-300 rounded-box text-ink-muted text-small flex h-40 items-center justify-center border border-dashed"
          >
            No scanned bill — this line appears in GSTR-2B only.
          </div>
        </div>

        <div id="gst-evidence-why" class="space-y-4">
          <div>
            <div class="text-ink-subtle text-label font-semibold uppercase">Vendor</div>
            <div class="text-base-content text-small mt-1 font-medium">
              {@selected_row["vendor_name"]}
            </div>
            <div :if={@selected_row["vendor_gstin"]} class="text-fine text-ink-subtle mt-0.5">
              {@selected_row["vendor_gstin"]}
            </div>
          </div>
          <div :if={@selected_row["recon_note"]}>
            <div class="text-ink-subtle text-label font-semibold uppercase">Recon note</div>
            <p class="text-base-content text-small mt-1">{@selected_row["recon_note"]}</p>
          </div>
          <div :if={@selected_row["next_action"]}>
            <div class="text-ink-subtle text-label font-semibold uppercase">Next action</div>
            <p class="text-base-content text-small mt-1">{@selected_row["next_action"]}</p>
          </div>
          <div :if={@selected_row["flags"] not in [nil, []]} class="space-y-2">
            <div class="text-ink-subtle text-label font-semibold uppercase">Flags</div>
            <div
              :for={flag <- @selected_row["flags"]}
              class="bg-base-200/40 border-base-300 rounded-box border p-3"
            >
              <.badge variant={if flag["severity"] == "error", do: "error", else: "warning"}>
                {issue_label(flag["code"])}
              </.badge>
              <p class="text-ink-muted text-small mt-2">{flag["reason"]}</p>
            </div>
          </div>
        </div>
      </div>
    </.modal>

    <.invoice_modal
      :if={@selected_invoice}
      selected_invoice={@selected_invoice}
      issues_by_invoice={@issues_by_invoice}
      r1_signoff={@r1_signoff}
      flagged={@flagged}
      correcting={@correcting}
    />
    """
  end

  attr :selected_invoice, :map, required: true
  attr :issues_by_invoice, :map, required: true
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

    assigns =
      assigns
      |> assign(:failed_checks, Enum.reject(checks, & &1["passed"]))
      |> assign(:check_issues, check_issues)
      |> assign(:other_issues, issues -- in_place)
      |> assign(:read_rows, read_rows(assigns.selected_invoice, checks))

    ~H"""
    <.modal
      id="gstr1-evidence-modal"
      title={@selected_invoice["invoice_number"] || "Invoice"}
      on_close="close-evidence"
      class="h-[90vh] max-w-384"
    >
      <div class="grid h-full min-h-0 gap-5 lg:grid-cols-[minmax(0,1.15fr)_minmax(0,1fr)]">
        <div id="gstr1-evidence-images" class="min-h-0 space-y-3 overflow-y-auto">
          <img
            :for={url <- @selected_invoice["image_urls"]}
            src={url}
            alt="Scanned sales bill"
            class="border-base-300 rounded-box w-full border"
          />
          <div
            :if={@selected_invoice["image_urls"] == []}
            class="border-base-300 rounded-box text-ink-muted text-small flex h-40 items-center justify-center border border-dashed"
          >
            No page image for this invoice.
          </div>
        </div>

        <div class="min-h-0 space-y-4 overflow-y-auto">
          <div>
            <div class="text-ink-subtle text-label font-semibold uppercase">Buyer</div>
            <div class="text-base-content text-small mt-1 font-medium">
              {@selected_invoice["buyer_name"] || "—"}
            </div>
            <div class="text-fine text-ink-subtle mt-0.5 font-mono">
              {@selected_invoice["buyer_gstin"] || "—"}
            </div>
          </div>

          <div :if={@read_rows != []} class="space-y-2">
            <div class="text-ink-subtle text-label font-semibold uppercase">Extracted read</div>
            <.data_table
              id="gstr1-line-items"
              rows={@read_rows}
              row_class={fn row -> row.kind == :total && "bg-base-200/40 font-medium" end}
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
              <:col :let={row} label="HSN">
                <span :if={row.kind == :line} class="font-mono">{row.line["hsn_sac"] || "—"}</span>
              </:col>
              <:col :let={row} label="Rate" align="right">
                <span :if={row.kind == :line}>{line_rate_label(row.line)}</span>
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
          </div>

          <div :if={@failed_checks != []} id="gstr1-checks" class="space-y-2">
            <div class="text-ink-subtle text-label font-semibold uppercase">
              What didn't check out
            </div>
            <%= for check <- @failed_checks do %>
              <.issue_card
                :if={@check_issues[check_key(check)]}
                issue={@check_issues[check_key(check)]}
                r1_signoff={@r1_signoff}
              />
              <div
                :if={is_nil(@check_issues[check_key(check)])}
                class="text-ink-muted text-small flex items-center gap-2"
              >
                <.icon name="hero-x-mark-mini" class="text-error size-4 shrink-0" />
                <span>{check_claim(check)}</span>
              </div>
            <% end %>
          </div>

          <div :if={@other_issues != []} class="space-y-2">
            <div class="text-ink-subtle text-label font-semibold uppercase">Issues</div>
            <.issue_card :for={issue <- @other_issues} issue={issue} r1_signoff={@r1_signoff} />
          </div>

          <div
            :if={Gstr1.correctable_fields(@flagged, @selected_invoice["pristine_inum"]) != []}
            id="gstr1-corrections"
            class="space-y-2"
          >
            <div class="text-ink-subtle text-label font-semibold uppercase">Flagged fields</div>
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
            <p class="text-ink-muted text-small">
              Only fields Nila flagged are correctable — fixing anything else would be a silent error.
            </p>
          </div>
        </div>
      </div>
    </.modal>
    """
  end

  attr :issue, :map, required: true
  attr :r1_signoff, :any, default: nil

  defp issue_card(assigns) do
    ~H"""
    <div class="bg-base-200/40 border-base-300 rounded-box border p-3">
      <.badge variant={
        if @issue["status"] == "resolved",
          do: "success",
          else: Helpers.severity_variant(@issue["level"])
      }>
        {issue_label(@issue["code"])}
      </.badge>
      <p class="text-ink-muted text-small mt-2 line-clamp-2">{@issue["message"]}</p>
      <div class="mt-2">
        <.button
          :if={@issue["status"] == "open" and is_nil(@r1_signoff)}
          variant="outline"
          size="xs"
          phx-click="confirm_issue"
          phx-value-target={SalesWorkings.issue_key(@issue)}
        >
          Checked against the bill — it's fine
        </.button>
        <span :if={@issue["status"] == "resolved"} class="flex items-center gap-1.5">
          <span class="text-fine text-success font-medium">Confirmed</span>
          <.button
            :if={is_nil(@r1_signoff)}
            variant="ghost"
            size="xs"
            phx-click="undo"
            phx-value-target={SalesWorkings.issue_key(@issue)}
          >Undo</.button>
        </span>
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
            line: line,
            verdict: verdict(Enum.filter(checks, &(&1["line"] == index)))
          }
        end)

      totals = Enum.filter(checks, &is_nil(&1["line"]))

      rows ++
        [%{kind: :total, totals: Gstr1.extracted_totals(invoice), verdict: verdict(totals)}]
    end
  end

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
