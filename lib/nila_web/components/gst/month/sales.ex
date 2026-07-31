defmodule NilaWeb.Components.Gst.Month.Sales do
  use NilaWeb, :html

  @moduledoc """
  GSTR-1 working surface: the complete invoice register, issues, and derived
  return evidence. Lifecycle never hides or replaces this material.
  """

  alias Nila.Gst.Sales.Gstr1
  alias Nila.Gst.Sales.Workings, as: SalesWorkings
  alias NilaWeb.Components.Gst.Month.Helpers
  alias NilaWeb.Components.Gst.Month.Workings

  attr :sales_month, :any, default: nil
  attr :invoices, :list, required: true
  attr :open_issue_count, :integer, required: true
  attr :r1_signoff, :any, default: nil
  attr :month_issues, :list, required: true
  attr :issues_by_invoice, :map, required: true
  attr :pages_read, :integer, default: nil
  attr :visited, :any, default: MapSet.new()
  attr :derived, :any, default: nil
  attr :diff, :any, default: nil
  attr :accepted_diffs, :any, default: MapSet.new()
  attr :rippled, :any, default: MapSet.new()
  attr :ripple_seq, :integer, default: 0
  attr :expanded_nodes, :any, default: MapSet.new()
  slot :source
  slot :actions

  def sales_section(assigns) do
    series = Gstr1.series_account(assigns.invoices)

    assigns =
      assigns
      |> assign(:series, series)
      |> assign(:account_note, account_note(assigns.pages_read, series))
      |> assign(:totals, month_totals(assigns.invoices))

    ~H"""
    <section :if={@sales_month} id="month-sales" class="space-y-section scroll-mt-28">
      <div class="space-y-block">
        <div>
          <p class="text-eyebrow text-moon font-semibold uppercase">Sales evidence</p>
          <h2 class="text-base-content text-h4 font-semibold">GSTR-1</h2>
        </div>
        {render_slot(@source)}
      </div>

      <div
        :if={@invoices != []}
        id="gstr1-account"
        class={[
          "border-base-300 gap-block py-block grid border-y sm:grid-cols-[minmax(0,1.4fr)_auto_auto]",
          Workings.ripple_class(@rippled, @ripple_seq, "gstr1-account")
        ]}
      >
        <div class="space-y-related">
          <p class="text-ink-subtle text-label font-semibold uppercase">Invoice run</p>
          <p class="text-base-content text-body font-medium">
            <%= if @series do %>
              {@series.from}–{@series.to}
              <a
                :if={@series.missing != []}
                href="#gstr1-month-issue-sequence_gaps"
                class="text-warning ml-2 hover:underline"
              >
                {gap_phrase(@series.missing)}
              </a>
              <span :if={@series.missing == []} class="text-success ml-2">Complete</span>
            <% else %>
              No numbered series
            <% end %>
          </p>
          <p :if={@account_note} class="text-ink-muted text-small">{@account_note}</p>
        </div>
        <div class="space-y-related sm:text-right">
          <p class="text-ink-subtle text-label font-semibold uppercase">Invoices</p>
          <p class="font-display text-base-content text-lead leading-none font-normal tabular-nums">
            {length(@invoices)}
          </p>
        </div>
        <div class="space-y-related sm:text-right">
          <p class="text-ink-subtle text-label font-semibold uppercase">Taxable + tax</p>
          <p class="font-display text-base-content text-lead leading-none font-normal tabular-nums">
            {rupees(@totals.taxable)} + {rupees(@totals.tax)}
          </p>
        </div>
      </div>

      <div :if={@month_issues != []} id="gstr1-month-issues" class="space-y-related">
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
          <span class="text-body text-ink-muted min-w-0 flex-1">{issue["message"]}</span>
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

      <section id="gstr1-register" class="space-y-block">
        <h3 class="text-base-content text-body font-semibold">Invoice register</h3>
        <.invoice_table
          id="gstr1-invoices"
          rows={@invoices}
          visited={@visited}
          issues_by_invoice={@issues_by_invoice}
        />
      </section>

      <section :if={@derived} id="gstr1-return" class="space-y-block">
        <h3 class="text-base-content text-body font-semibold">Return workings</h3>
        <Workings.workings_body
          derived={@derived}
          invoices={@invoices}
          diff={@diff}
          accepted={@accepted_diffs}
          locked={@r1_signoff != nil}
          rippled={@rippled}
          ripple_seq={@ripple_seq}
          expanded={@expanded_nodes}
        />
      </section>

      {render_slot(@actions)}
    </section>
    """
  end

  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :visited, :any, default: MapSet.new()
  attr :issues_by_invoice, :map, required: true

  defp invoice_table(assigns) do
    ~H"""
    <.data_table
      id={@id}
      rows={@rows}
      row_id={fn invoice -> "gstr1-inv-#{invoice["invoice_number"]}" end}
      row_click={
        fn invoice -> JS.push("select-invoice", value: %{inum: invoice["invoice_number"]}) end
      }
      min_width="min-w-[760px]"
    >
      <:col :let={invoice} label="Inv No">
        <span class={[
          "font-mono",
          (MapSet.member?(@visited, invoice["invoice_number"]) && "text-primary/60") ||
            "text-primary font-medium"
        ]}>
          {invoice["invoice_number"] || "—"}
        </span>
      </:col>
      <:col :let={invoice} label="Date">
        {Nila.Formatters.format_display_date(invoice["invoice_date"])}
      </:col>
      <:col :let={invoice} label="Buyer">
        <span class="block max-w-64 truncate" title={invoice["buyer_name"]}>
          {invoice["buyer_name"] || "—"}
        </span>
      </:col>
      <:col :let={invoice} label="Buyer GSTIN">
        <span class="text-ink-muted font-mono">{invoice["buyer_gstin"] || "—"}</span>
      </:col>
      <:col :let={invoice} label="Taxable" align="right">
        {rupees(Gstr1.extracted_totals(invoice).taxable)}
      </:col>
      <:col :let={invoice} label="Tax" align="right">
        {rupees(Gstr1.extracted_totals(invoice).tax)}
      </:col>
      <:col :let={invoice} label="Review">
        <% state = invoice_state(@issues_by_invoice, invoice) %>
        <.badge :if={state} variant={state.variant}>{state.label}</.badge>
      </:col>
      <:col label="" align="right">
        <.icon name="hero-chevron-right-mini" class="text-ink-faint size-4" />
      </:col>
      <:empty>No sales invoices were extracted for this month.</:empty>
    </.data_table>
    """
  end

  defp invoice_state(issues_by_invoice, invoice) do
    issues = Helpers.invoice_issues(issues_by_invoice, invoice)
    open = Enum.count(issues, &(&1["status"] == "open"))

    cond do
      open > 0 -> %{variant: "warning", label: issues_clause(open)}
      issues != [] -> %{variant: "success", label: "Confirmed"}
      true -> nil
    end
  end

  defp gap_phrase([gap]), do: "Gap at #{gap}"
  defp gap_phrase(gaps), do: "Gaps at #{Enum.join(gaps, ", ")}"

  defp account_note(pages, series) do
    duplicates = (series && series.duplicates) || []

    [
      is_integer(pages) && "#{pages} #{plural(pages, "page")} read",
      duplicates != [] && "Duplicates: #{Enum.join(duplicates, ", ")}"
    ]
    |> Enum.filter(& &1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  defp issues_clause(0), do: "No open issues"
  defp issues_clause(1), do: "1 to check"
  defp issues_clause(n), do: "#{n} to check"

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"

  defp month_totals(invoices) do
    Enum.reduce(invoices, %{taxable: 0, tax: 0}, fn invoice, acc ->
      totals = Gstr1.extracted_totals(invoice)
      %{taxable: acc.taxable + totals.taxable, tax: acc.tax + totals.tax}
    end)
  end

  defp rupees(amount), do: Helpers.rupees(amount)
end
