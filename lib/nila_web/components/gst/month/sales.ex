defmodule NilaWeb.Components.Gst.Month.Sales do
  use NilaWeb, :html

  @moduledoc """
  GSTR-1 working surface: the month's account, its issues and its invoices.

  Folded by default and unfolded when the sales track owns the door, because
  the sales side is only ever one of two tracks and the one that is not being
  worked has no claim on the reader's attention. Signatures and ARNs are not
  here; they live in the exit block with the GSTR-3B's, so the page has exactly
  one place where a return gets closed.

  The unfolded body opens with the account — what came in and what it became,
  gaps confessed before anyone asks — then the work: month issues, the invoices
  that need a human, and the verified rest collapsed to a count. In the tables,
  silence means verified; only open work gets ink.
  """

  alias Nila.Gst.Sales.Gstr1
  alias Nila.Gst.Sales.Workings, as: SalesWorkings
  alias NilaWeb.Components.Gst.Month.Helpers
  alias NilaWeb.Components.Gst.Month.Workings

  attr :sales_month, :any, default: nil
  attr :invoices, :list, required: true
  attr :open_issue_count, :integer, required: true
  attr :reviewable, :boolean, required: true
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
  attr :open, :boolean, default: false

  def sales_section(assigns) do
    {need_you, verified} =
      Enum.split_with(assigns.invoices, &(open_issues(assigns.issues_by_invoice, &1) > 0))

    assigns =
      assigns
      |> assign(:need_you, need_you)
      |> assign(:verified, verified)
      |> assign(:series, Gstr1.series_account(assigns.invoices))
      |> assign(:totals, month_totals(assigns.invoices))

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
        <span class="flex-1 truncate">{sales_summary_line(assigns)}</span>
        <.icon
          name="hero-chevron-down-mini"
          class="text-base-content/40 size-4 shrink-0 transition-transform group-open:rotate-180"
        />
      </summary>

      <div class="mt-3 space-y-3">
        <p
          :if={@invoices != []}
          id="gstr1-account"
          class={[
            "text-base-content/70 text-small",
            Workings.ripple_class(@rippled, @ripple_seq, "gstr1-account")
          ]}
        >
          {account_lead(assigns)}<a
            :if={@series && @series.missing != []}
            href="#gstr1-month-issue-sequence_gaps"
            class="text-warning hover:underline"
          >{gap_phrase(@series.missing)}</a>{account_tail(assigns)}
        </p>

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

        <div :if={@need_you != []} class="space-y-2">
          <p class="text-base-content/70 text-small">
            {length(@need_you)} need you
          </p>
          <.invoice_table
            id="gstr1-invoices"
            rows={@need_you}
            issues_by_invoice={@issues_by_invoice}
            visited={@visited}
          />
        </div>

        <Workings.workings_body
          :if={@derived}
          derived={@derived}
          invoices={@invoices}
          diff={@diff}
          accepted={@accepted_diffs}
          locked={@r1_signoff != nil}
          rippled={@rippled}
          ripple_seq={@ripple_seq}
        />

        <details :if={@verified != []} id="gstr1-verified" class="group/verified">
          <summary class="hover:text-base-content text-base-content/60 text-small flex cursor-pointer list-none items-center gap-1.5">
            <.icon
              name="hero-chevron-right-mini"
              class="size-4 shrink-0 transition-transform group-open/verified:rotate-90"
            />
            {length(@verified)} verified
          </summary>
          <div class="mt-2">
            <.invoice_table
              id="gstr1-invoices-verified"
              rows={@verified}
              issues_by_invoice={@issues_by_invoice}
              visited={@visited}
            />
          </div>
        </details>
      </div>
    </details>
    """
  end

  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :issues_by_invoice, :map, required: true
  attr :visited, :any, default: MapSet.new()

  defp invoice_table(assigns) do
    ~H"""
    <.data_table
      id={@id}
      rows={@rows}
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
          <%!-- Read rows go quiet, mail-style — the mark is the weight itself,
                not a glyph to decorate every row with. --%>
          <span class={
            if MapSet.member?(@visited, invoice["invoice_number"]),
              do: "text-base-content/60",
              else: "font-medium"
          }>
            {invoice["invoice_number"] || "—"}
          </span>
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
      </:col>
    </.data_table>
    """
  end

  # "15 invoices · series 92 – 107, gap at 103 · 3 to check" — the fold keeps
  # the what-needs-me signal last so it survives truncation worst, but the
  # series confession rides along even while the section is closed.
  defp sales_summary_line(assigns) do
    count = length(assigns.invoices)

    parts =
      [
        "#{count} #{plural(count, "invoice")}",
        series_clause(assigns.series),
        issues_clause(assigns.open_issue_count)
      ]
      |> Enum.reject(&is_nil/1)

    "GSTR-1: " <> Enum.join(parts, " · ")
  end

  defp series_clause(nil), do: nil
  defp series_clause(%{missing: []} = series), do: "series #{series.from} – #{series.to}"

  defp series_clause(series),
    do: "series #{series.from} – #{series.to}, #{gap_phrase(series.missing)}"

  defp gap_phrase([gap]), do: "gap at #{gap}"
  defp gap_phrase(gaps), do: "gaps at #{Enum.join(gaps, ", ")}"

  defp duplicates_phrase([]), do: "no duplicates"
  defp duplicates_phrase(duplicates), do: "duplicates: #{Enum.join(duplicates, ", ")}"

  # The account reads as one quiet sentence — pages read → invoices found,
  # series, duplicates, totals. Only the gap gets markup: the anchor into the
  # issue card that demands the decision, so the fact and the question never
  # drift apart. Lead ends mid-sentence when a gap link follows.
  defp account_lead(assigns) do
    lead =
      "#{pages_clause(assigns)}#{length(assigns.invoices)} #{plural(length(assigns.invoices), "invoice")}"

    case assigns.series do
      nil -> lead
      %{missing: []} = series -> "#{lead} · series #{series.from} – #{series.to}, complete"
      series -> "#{lead} · series #{series.from} – #{series.to}, "
    end
  end

  defp account_tail(assigns) do
    duplicates =
      case assigns.series do
        nil -> ""
        series -> " · #{duplicates_phrase(series.duplicates)}"
      end

    "#{duplicates} · #{rupees(assigns.totals.taxable)} taxable + #{rupees(assigns.totals.tax)} tax"
  end

  defp pages_clause(%{pages_read: pages}) when is_integer(pages),
    do: "#{pages} #{plural(pages, "page")} read → "

  defp pages_clause(_assigns), do: ""

  defp issues_clause(0), do: "no open issues"
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

  defp open_issues(issues_by_invoice, invoice) do
    issues_by_invoice
    |> Helpers.invoice_issues(invoice)
    |> Enum.count(&(&1["status"] == "open"))
  end

  defp rupees(amount), do: Helpers.rupees(amount)
end
