defmodule NilaWeb.Components.Gst.Month.Sales do
  use NilaWeb, :html

  @moduledoc "GSTR-1 sales presentation for the GST month workbench."

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
  attr :can_sign_off, :boolean, required: true
  attr :client, :map, required: true
  attr :period, :string, required: true

  def sales_section(assigns) do
    ~H"""
    <section :if={@sales_month} id="month-sales" class="scroll-mt-28 space-y-4">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h2 class="text-base-content font-semibold">GSTR-1 — outward</h2>
          <p class="text-base-content/60 text-small">
            {length(@invoices)} invoices ·
            <span class={[
              @open_issue_count > 0 && "text-warning",
              @open_issue_count == 0 && "text-base-content/60"
            ]}>
              {@open_issue_count} open issues
            </span>
          </p>
        </div>
        <div class="flex items-center gap-2">
          <span :if={@sales_month.state == "reviewed"} id="gstr1-reviewed-badge">
            <.badge variant="success">Reviewed</.badge>
          </span>
          <.button
            :if={@sales_month.state == "worked" and @reviewable}
            id="gstr1-mark-reviewed"
            phx-click="mark_reviewed"
            variant="success"
            size="sm"
          >
            <.icon name="hero-check-circle" class="size-4" /> Mark reviewed
          </.button>
          <.button
            :if={@sales_month.state == "reviewed" and is_nil(@r1_signoff) and @can_sign_off}
            id="gstr1-signoff-button"
            phx-click="r1-sign-off"
            variant="primary"
            size="sm"
          >
            <.icon name="hero-check-badge-mini" class="size-4" /> Sign off GSTR-1
          </.button>
          <.button
            id="gstr1-download-json"
            href={~p"/gstr1/#{@sales_month.client_id}/#{@sales_month.period}/return.json"}
            variant={if @r1_signoff, do: "outline", else: "primary"}
            size="sm"
          >
            <.icon name="hero-arrow-down-tray" class="size-4" /> Portal JSON
          </.button>
        </div>
      </div>

      <div
        :if={@r1_signoff}
        id="gstr1-signoff-banner"
        class="bg-success/[0.04] border-success/40 rounded-box space-y-3 border px-4 py-3"
      >
        <div class="flex items-start gap-2">
          <.icon name="hero-check-badge" class="text-success size-5 shrink-0" />
          <p class="text-base-content text-small flex-1">
            GSTR-1 signed off by {(@r1_signoff.signed_by && @r1_signoff.signed_by.name) || "—"} · {format_display_datetime(
              @r1_signoff.inserted_at
            )} — figures are frozen as approved.
            <span :if={@sales_month.filed_at} id="gstr1-filed-note" class="font-medium">
              Filed {format_display_datetime(@sales_month.filed_at)}{if @sales_month.filing_arn,
                do: " · ARN #{@sales_month.filing_arn}"}.
            </span>
          </p>
          <.button
            :if={@can_sign_off and is_nil(@sales_month.filed_at)}
            id="gstr1-reopen-signoff"
            variant="ghost"
            size="xs"
            phx-click="r1-reopen-signoff"
            data-confirm="Reopen this signed GSTR-1? The signature is revoked — and any GSTR-3B signed against it is reopened too."
          >
            Reopen
          </.button>
        </div>

        <ol :if={is_nil(@sales_month.filed_at)} class="space-y-2 pl-7">
          <li class="text-small flex flex-wrap items-center gap-2">
            <span class="text-base-content/50 font-mono">1.</span>
            <span class="text-base-content flex-1">Download the portal JSON</span>
            <.button
              id="gstr1-guide-download-json"
              href={~p"/gstr1/#{@sales_month.client_id}/#{@sales_month.period}/return.json"}
              variant="outline"
              size="xs"
            >
              Download JSON
            </.button>
          </li>
          <li class="text-small flex items-center gap-2">
            <span class="text-base-content/50 font-mono">2.</span>
            <span class="text-base-content flex-1">File it at gst.gov.in</span>
            <a
              href="https://www.gst.gov.in/"
              target="_blank"
              rel="noopener"
              class="text-moon font-semibold"
            >
              Open portal →
            </a>
          </li>
          <li>
            <form
              id="gstr1-mark-filed"
              phx-submit="r1-mark-filed"
              class="text-small flex flex-wrap items-center gap-2"
            >
              <span class="text-base-content/50 font-mono">3.</span>
              <span class="text-base-content flex-1">Paste the ARN here</span>
              <.input
                type="text"
                name="arn"
                id="gstr1-filed-arn"
                value=""
                placeholder="ARN (optional)"
                class="input input-sm w-40 font-mono"
                autofocus
              />
              <.button type="submit" variant="success" size="xs">Filed on portal</.button>
            </form>
          </li>
        </ol>
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
          <span class="text-base-content/80 text-small line-clamp-2 min-w-0 flex-1">{issue["message"]}</span>
          <.button
            :if={issue["status"] == "open" and is_nil(@r1_signoff)}
            variant="outline"
            size="xs"
            phx-click="confirm_issue"
            phx-value-target={SalesWorkings.issue_key(issue)}
          >
            Checked — it's fine
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
        sticky_header="xl:top-16"
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
        <:col :let={invoice} label="Date">{invoice["invoice_date"] || "—"}</:col>
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
    </section>

    <div
      :if={!@sales_month}
      id="month-sales-missing"
      class="border-base-300 rounded-box text-base-content/60 text-small flex scroll-mt-28 flex-wrap items-center gap-2 border border-dashed px-4 py-2.5"
    >
      <span class="flex-1">Sales bills not in yet — the GSTR-1 derives once they arrive.</span>
      <.link
        navigate={~p"/gst/upload?client_id=#{@client.id}&period=#{@period}"}
        class="text-moon font-semibold"
      >
        Bring them in →
      </.link>
    </div>
    """
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
