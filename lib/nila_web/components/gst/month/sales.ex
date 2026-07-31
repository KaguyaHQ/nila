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
  that need a human, the workings, and the verified rest collapsed to a count.
  In the tables, silence means verified; only open work gets ink.

  That law is easy to keep inside a table and easy to break around one. Each
  count is told exactly once — the verdict and its door say how many issues
  there are, so the fold hides its own summary when it opens and no caption
  counts the rows again. The portal JSON is not here either: it is the first
  step after a signature, and the exit block owns it.
  """

  alias Nila.Gst.Sales.Gstr1
  alias Nila.Gst.Sales.Workings, as: SalesWorkings
  alias NilaWeb.Components.Gst.Month.Helpers
  alias NilaWeb.Components.Gst.Month.Workings

  attr :sales_month, :any, default: nil
  attr :invoices, :list, required: true
  attr :open_issue_count, :integer, required: true
  attr :reviewable, :boolean, required: true

  attr :review_door_taken, :boolean,
    default: false,
    doc: "the verdict's door is already \"Mark the GSTR-1 reviewed\""

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
  attr :open_folds, :any, default: MapSet.new()
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
    <%!-- Of the four folds stacked on this page this is the only one that is
          work; settled, register and paper trail are appendices. So this one
          alone is set as a heading — a reader looking for the GSTR-1 should
          find it without reading four identical grey lines to tell them apart. --%>
    <.fold
      :if={@sales_month}
      id="month-sales"
      open={@open}
      summary_class="text-base-content text-body font-semibold"
    >
      <:summary>
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
        <%!-- Closed, the fold has to carry the month; open, the account line
              below it says the same thing at more length, and two near-identical
              strings stacked is what makes a page read like a journal. So the
              detail is CSS-folded away the moment the section opens. --%>
        <span class="flex-1 truncate">
          GSTR-1<span class="text-ink-muted text-small font-normal group-open/fold:hidden">
            · {sales_summary_line(assigns)}
          </span>
        </span>
      </:summary>

      <div class="mt-block space-y-block">
        <p
          :if={@invoices != []}
          id="gstr1-account"
          class={[
            "text-ink-muted text-small",
            Workings.ripple_class(@rippled, @ripple_seq, "gstr1-account")
          ]}
        >
          {account_lead(assigns)}<a
            :if={@series && @series.missing != []}
            href="#gstr1-month-issue-sequence_gaps"
            class="text-warning hover:underline"
          >{gap_phrase(@series.missing)}</a>{account_tail(assigns)}
        </p>

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
            <span class="text-ink-muted text-small line-clamp-2 min-w-0 flex-1">{issue[
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

        <%!-- No caption counting these rows: the verdict said the count, the
              door said it, the fold said it. A fourth telling buys nothing and
              costs a parse. The rows are the count. --%>
        <.invoice_table :if={@need_you != []} id="gstr1-invoices" rows={@need_you} visited={@visited} />

        <section :if={@derived} id="gstr1-return" class="space-y-block">
          <div class="space-y-related">
            <h3 class="text-base-content text-body font-semibold">Return workings</h3>
            <p class="text-ink-muted text-small">{workings_summary_line(assigns)}</p>
          </div>
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

        <.fold
          :if={@verified != []}
          id="gstr1-verified"
          open={MapSet.member?(@open_folds, "gstr1-verified")}
        >
          <:summary>
            <span class="flex-1">{length(@verified)} verified</span>
          </:summary>
          <div class="mt-block">
            <.invoice_table id="gstr1-invoices-verified" rows={@verified} visited={@visited} />
          </div>
        </.fold>

        <%!-- The done gesture sits after the work, not above it — and only when
              the verdict has not already taken it. Whenever the sales track owns
              the door, "Mark the GSTR-1 reviewed" *is* the door, and a second
              outline copy a screen below it is the page asking its own question
              twice. It survives for the case the door can't cover: sales worked
              and clean while purchase still owns the door. The portal JSON is
              not here at all — that is the first step after a signature, and the
              exit block owns it. --%>
        <div :if={
          @sales_month.state == "reviewed" or
            (@sales_month.state == "worked" and @reviewable and not @review_door_taken)
        }>
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
        </div>
      </div>
    </.fold>
    """
  end

  attr :id, :string, required: true
  attr :rows, :list, required: true
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
      <%!-- No warning glyph per row: every row in this table needs you, and a
            mark that never varies distinguishes nothing. The invoice number is
            the affordance instead — the same blue mono it wears as a contributor
            in the workings, so "invoice number opens the invoice" is one mark to
            learn and it appears wherever the click does. Read rows go quiet,
            mail-style: the weight is the mark, not a glyph. --%>
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
      <%!-- Extracted buyer names carry the whole registered address. Capped and
            truncated, or one row is three lines tall and the money leaves the
            screen; the full string stays on hover. --%>
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
      <%!-- No "Issues" column. Every row above the verified fold has open issues
            and every row below it has none, so the column read "1 open" or
            "resolved" all the way down — a label for a fact the table's own
            shape already states. --%>
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

    Enum.join(parts, " · ")
  end

  # What the fold is hiding, in the shape it will be read in: the return's own
  # sections, sized. Never a match score — the diff speaks for itself inside.
  defp workings_summary_line(assigns) do
    derived = assigns.derived

    parts =
      [
        count_clause(length(derived["b2b"] || []), "party", "parties"),
        count_clause(length(Gstr1.rate_summary(derived)), "rate", "rates"),
        count_clause(length(Gstr1.hsn_summary(assigns.invoices)), "HSN code", "HSN codes")
      ]
      |> Enum.reject(&is_nil/1)

    case parts do
      [] -> "The return"
      parts -> "The return · " <> Enum.join(parts, " · ")
    end
  end

  defp count_clause(0, _one, _many), do: nil
  defp count_clause(1, one, _many), do: "1 #{one}"
  defp count_clause(n, _one, many), do: "#{n} #{many}"

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
