defmodule NilaWeb.Components.Gst.Month.Sales do
  use NilaWeb, :html

  @moduledoc """
  GSTR-1 working surface: the month's issues and its invoice table.

  Folded by default and unfolded when the sales track owns the door, because
  the sales side is only ever one of two tracks and the one that is not being
  worked has no claim on the reader's attention. Signatures and ARNs are not
  here; they live in the exit block with the GSTR-3B's, so the page has exactly
  one place where a return gets closed.
  """

  alias Nila.Gst.Sales.Gstr1
  alias Nila.Gst.Sales.Workings, as: SalesWorkings
  alias NilaWeb.Components.Gst.Month.Helpers

  attr :sales_month, :any, default: nil
  attr :invoices, :list, required: true
  attr :open_issue_count, :integer, required: true
  attr :reviewable, :boolean, required: true
  attr :r1_signoff, :any, default: nil
  attr :month_issues, :list, required: true
  attr :issues_by_invoice, :map, required: true
  attr :open, :boolean, default: false

  def sales_section(assigns) do
    ~H"""
    <details :if={@sales_month} id="month-sales" open={@open} class="group scroll-mt-28">
      <summary class="hover:text-base-content text-base-content/70 text-small flex cursor-pointer list-none items-center gap-2">
        <.icon
          name={
            if @open_issue_count > 0,
              do: "hero-exclamation-triangle-mini",
              else: "hero-check-circle-mini"
          }
          class={[
            "size-4 shrink-0",
            (@open_issue_count > 0 && "text-warning") || "text-success"
          ]}
        />
        <span class="flex-1">{sales_summary_line(assigns)}</span>
        <.icon
          name="hero-chevron-down-mini"
          class="text-base-content/40 size-4 shrink-0 transition-transform group-open:rotate-180"
        />
      </summary>

      <div class="mt-3 space-y-3">
        <div class="flex flex-wrap items-center gap-2">
          <span :if={@sales_month.state == "reviewed"} id="gstr1-reviewed-badge">
            <.badge variant="success">Reviewed</.badge>
          </span>
          <.button
            :if={@sales_month.state == "worked" and @reviewable}
            id="gstr1-mark-reviewed"
            phx-click="mark_reviewed"
            variant="outline"
            size="sm"
          >
            <.icon name="hero-check-circle" class="size-4" /> Mark reviewed
          </.button>
          <.button
            id="gstr1-download-json"
            href={~p"/gstr1/#{@sales_month.client_id}/#{@sales_month.period}/return.json"}
            variant="outline"
            size="sm"
          >
            <.icon name="hero-arrow-down-tray" class="size-4" /> Portal JSON
          </.button>
        </div>

        <div :if={@month_issues != []} id="gstr1-month-issues" class="space-y-2">
          <div
            :for={issue <- @month_issues}
            id={"gstr1-month-issue-#{issue["code"]}"}
            class="border-base-300 rounded-box flex flex-wrap items-center gap-3 border px-4 py-3"
          >
            <.badge variant={
              if issue["status"] == "resolved",
                do: "success",
                else: Helpers.severity_variant(issue["level"])
            }>
              {issue_label(issue["code"])}
            </.badge>
            <span class="text-base-content/80 text-small line-clamp-2 min-w-0 flex-1">{issue[
              "message"
            ]}</span>
            <.button
              :if={issue["status"] == "open" and is_nil(@r1_signoff)}
              variant="outline"
              size="xs"
              phx-click="confirm_issue"
              phx-value-target={SalesWorkings.issue_key(issue)}
            >
              Checked, it's fine
            </.button>
            <span :if={issue["status"] == "resolved"} class="flex items-center gap-1.5">
              <span class="text-fine text-success font-medium">Confirmed</span>
              <.button
                :if={is_nil(@r1_signoff)}
                variant="ghost"
                size="xs"
                phx-click="undo"
                phx-value-target={SalesWorkings.issue_key(issue)}
              >
                Undo
              </.button>
            </span>
          </div>
        </div>

        <.data_table
          id="gstr1-invoices"
          rows={@invoices}
          row_id={fn invoice -> "gstr1-inv-#{invoice["invoice_number"]}" end}
          row_click={
            fn invoice -> JS.push("select-invoice", value: %{inum: invoice["invoice_number"]}) end
          }
          min_width="min-w-[720px]"
        >
          <:col :let={invoice} label="Inv No">
            <div class="flex items-center gap-2">
              <.icon
                :if={open_issues(@issues_by_invoice, invoice) > 0}
                name="hero-exclamation-triangle-mini"
                class="text-warning size-4 shrink-0"
              />
              <span class="font-medium">{invoice["invoice_number"] || "—"}</span>
            </div>
          </:col>
          <:col :let={invoice} label="Date">
            {Nila.Formatters.format_display_date(invoice["invoice_date"])}
          </:col>
          <:col :let={invoice} label="Buyer">{invoice["buyer_name"] || "—"}</:col>
          <:col :let={invoice} label="Buyer GSTIN">
            <span class="text-fine font-mono">{invoice["buyer_gstin"] || "—"}</span>
          </:col>
          <:col :let={invoice} label="Taxable" align="right">
            {rupees(Gstr1.extracted_totals(invoice).taxable)}
          </:col>
          <:col :let={invoice} label="Tax" align="right">
            {rupees(Gstr1.extracted_totals(invoice).tax)}
          </:col>
          <:col :let={invoice} label="Issues">
            <span :if={open_issues(@issues_by_invoice, invoice) > 0} class="text-small text-warning">
              {open_issues(@issues_by_invoice, invoice)} open
            </span>
            <span
              :if={
                open_issues(@issues_by_invoice, invoice) == 0 and
                  Helpers.invoice_issues(@issues_by_invoice, invoice) != []
              }
              class="text-small text-success"
            >resolved</span>
            <span
              :if={Helpers.invoice_issues(@issues_by_invoice, invoice) == []}
              class="text-base-content/35 text-fine"
            >
              clean
            </span>
          </:col>
        </.data_table>
      </div>
    </details>
    """
  end

  defp sales_summary_line(assigns) do
    count = length(assigns.invoices)
    invoices = "#{count} #{if count == 1, do: "invoice", else: "invoices"}"

    case assigns.open_issue_count do
      0 -> "GSTR-1: #{invoices}, no open issues."
      1 -> "GSTR-1: #{invoices}, 1 issue to check."
      n -> "GSTR-1: #{invoices}, #{n} issues to check."
    end
  end

  defp open_issues(issues_by_invoice, invoice) do
    issues_by_invoice
    |> Helpers.invoice_issues(invoice)
    |> Enum.count(&(&1["status"] == "open"))
  end

  defp rupees(amount) when is_number(amount),
    do: Nila.Formatters.format_money_with_paise(round(amount * 100))

  defp rupees(_), do: "—"
end
