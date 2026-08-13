defmodule NilaWeb.Components.Gst.Month.Sales do
  use NilaWeb, :html

  @moduledoc """
  GSTR-1 working surface: the complete invoice register, issues, and derived
  return evidence. Lifecycle never hides or replaces this material.
  """

  alias Nila.Gst.Issues
  alias Nila.Gst.Sales.Gstr1
  alias Nila.Gst.Sales.Values
  alias Nila.Gst.Sales.Workings, as: SalesWorkings
  alias NilaWeb.Components.Gst.Month.Helpers
  alias NilaWeb.Components.Gst.Month.Workings

  attr :sales_month, :any, default: nil
  attr :client, :map, required: true
  attr :period, :string, required: true
  attr :invoices, :list, required: true
  attr :active_invoices, :list, required: true
  attr :open_issue_count, :integer, required: true
  attr :account, :map, required: true
  attr :r1_signoff, :any, default: nil
  attr :readiness, :map, required: true
  attr :issues_by_invoice, :map, required: true
  attr :pages_read, :integer, default: nil
  attr :visited, :any, default: MapSet.new()
  attr :reviewed_invoice, :string, default: nil
  attr :derived, :any, default: nil
  attr :diff, :any, default: nil
  attr :accepted_diffs, :any, default: MapSet.new()
  attr :rippled, :any, default: MapSet.new()
  attr :ripple_seq, :integer, default: 0
  attr :expanded_nodes, :any, default: MapSet.new()
  slot :source
  slot :actions

  def sales_section(%{sales_month: nil} = assigns) do
    ~H"""
    """
  end

  def sales_section(assigns) do
    assigns =
      assigns
      |> assign(:required_issues, assigns.account.issues.required)
      |> assign(:hsn_summary, Gstr1.hsn_summary(assigns.active_invoices))
      |> assign(:hsn_issues, hsn_issues(assigns.account.issues.required))
      |> assign(:novelty, novelty(assigns.account.issues.advisory))
      |> assign(:document_summary_rows, document_summary_rows(assigns.derived))
      |> then(&assign(&1, :novelty_codes, if(&1.novelty, do: &1.novelty.codes, else: [])))
      |> then(&assign(&1, :hsn_totals, hsn_totals(&1.hsn_summary)))

    ~H"""
    <section :if={@sales_month} id="month-sales" class="space-y-section scroll-mt-28">
      <section
        id="gstr1-verdict"
        class={[
          "border-base-300 pb-block space-y-related border-b",
          Workings.ripple_class(@rippled, @ripple_seq, "gstr1-account")
        ]}
      >
        <div class="flex flex-wrap items-start justify-between gap-4">
          <div class="min-w-0 space-y-1">
            <h2 class="text-base-content text-h4 font-semibold">
              {track_title(@sales_month, @r1_signoff)}
            </h2>
            <p
              :if={is_nil(@r1_signoff) and @account.issues.required_count > 0}
              id="gstr1-required-summary"
              class="text-base-content text-body"
            >
              {Helpers.work_clause(@account.issues.by_kind)} required before approval
            </p>
            <p
              :if={not is_nil(@r1_signoff) or @account.issues.required_count == 0}
              id="gstr1-lifecycle-summary"
              class="text-body text-ink-muted"
            >
              {@readiness.status}
            </p>
          </div>
          <.button
            :if={is_nil(@r1_signoff) and @required_issues != []}
            id="gstr1-review-required"
            patch={sales_review_path(@client, @period, nil, :needs_you)}
            variant="primary"
            size="sm"
          >
            Review required items
          </.button>
        </div>
        <p id="gstr1-draft-position" class="text-body text-ink-muted tabular-nums">
          <span id="gstr1-draft-invoices">
            {document_mix_label(@active_invoices)} in draft
          </span>
          <span aria-hidden="true"> · </span>
          <span id="gstr1-draft-taxable">
            {Helpers.rupees(@account.draft.totals.taxable)} taxable
          </span>
          <span aria-hidden="true"> · </span>
          <span id="gstr1-draft-output-tax">
            {Helpers.rupees(@account.draft.totals.tax)} proposed output tax
          </span>
        </p>
      </section>

      <section
        :if={@required_issues != []}
        id="gstr1-checks-before-filing"
        class="space-y-block scroll-mt-28"
      >
        <h3 class="sr-only">Required work</h3>
        <%!-- A blocker is a gap in this engine, not a defect in the client's
              bills, and nothing on this page can clear one. Saying so names the
              move that is actually available instead of leaving the month
              parked against a wall. --%>
        <p
          :if={Map.get(@account.issues.by_kind, :blocked, 0) > 0}
          id="gstr1-blocked-next-move"
          class="bg-error/5 border-error/30 rounded-box text-base-content text-body border px-4 py-3"
        >
          Nila files taxable B2B and B2C invoices plus registered credit and debit notes, but another document type in this month is unsupported. File {Nila.Formatters.period_label(
            @period
          )} for {@client.name} manually on the portal — and tell us
          which table you needed.
        </p>
        <div class="space-y-related">
          <article
            :for={issue <- @required_issues}
            id={
              "gstr1-required-#{:erlang.phash2({SalesWorkings.issue_key(issue), issue["message"]})}"
            }
            class="border-base-300 rounded-box flex flex-wrap items-center gap-3 border px-4 py-3"
          >
            <div class="min-w-0 flex-1 space-y-1">
              <p
                :if={issue["invoice"]}
                data-role="issue-invoice"
                class="text-base-content text-body font-semibold"
              >
                Invoice {issue["invoice"]}
              </p>
              <div data-role="issue-context" class="flex flex-wrap items-center gap-2">
                <.badge variant={Helpers.severity_variant(issue["level"])}>
                  {issue_label(issue["code"])}
                </.badge>
                <p class="text-body text-ink-muted">{issue["message"]}</p>
              </div>
            </div>
            <.button
              :if={
                is_binary(issue["hsn_code"]) and
                  not hsn_reviewed?(issue, @active_invoices, @expanded_nodes)
              }
              href="#gstr1-workings-hsn"
              variant="outline"
              size="xs"
              phx-click="review-hsn-issue"
              phx-value-code={Enum.join(hsn_codes(issue), ",")}
            >
              Review HSN rows
            </.button>
            <%!-- Only after the rows have actually been opened: confirming an
                  HSN check you have not looked at is not an answer. --%>
            <.button
              :if={
                is_binary(issue["hsn_code"]) and
                  hsn_reviewed?(issue, @active_invoices, @expanded_nodes) and
                  is_nil(issue["source_id"])
              }
              variant="outline"
              size="xs"
              phx-click="confirm_issue"
              phx-value-target={SalesWorkings.issue_key(issue)}
            >
              Confirm from records
            </.button>
            <.button
              :if={
                is_binary(issue["hsn_code"]) and
                  hsn_reviewed?(issue, @active_invoices, @expanded_nodes) and
                  is_binary(issue["source_id"])
              }
              variant="outline"
              size="xs"
              patch={
                sales_review_path(
                  @client,
                  @period,
                  issue["source_id"],
                  :needs_you,
                  SalesWorkings.issue_key(issue)
                )
              }
            >
              Review invoice
            </.button>
            <.button
              :if={!is_binary(issue["hsn_code"]) and issue["code"] == "duplicate_invoice_number"}
              variant="outline"
              size="xs"
              phx-click="open-duplicate-review"
              phx-value-target={SalesWorkings.issue_key(issue)}
            >
              Review copies
            </.button>
            <.button
              :if={!is_binary(issue["hsn_code"]) and is_binary(issue["source_id"])}
              variant="outline"
              size="xs"
              patch={
                sales_review_path(
                  @client,
                  @period,
                  issue["source_id"],
                  :needs_you,
                  SalesWorkings.issue_key(issue)
                )
              }
            >
              Review
            </.button>
            <.button
              :if={
                !is_binary(issue["hsn_code"]) and is_nil(issue["source_id"]) and
                  Issues.resolution_kind(issue) == :confirmation
              }
              variant="outline"
              size="xs"
              phx-click="confirm_issue"
              phx-value-target={SalesWorkings.issue_key(issue)}
            >
              Confirm from records
            </.button>
          </article>
        </div>
      </section>

      <%!-- Nila's answer comes before the machinery that produced it. Table 12
            and Table 13 are parts of that answer, not independent proof that
            the source month is complete or reconciled to books. --%>
      <section :if={@derived} id="gstr1-filing-summary" class="space-y-block">
        <div class="space-y-1">
          <h3 class="text-base-content text-h4 font-semibold">{@readiness.title}</h3>
          <p
            id="gstr1-filing-status"
            class={[
              "text-body",
              @readiness.state == :provisional && "text-warning",
              @readiness.state != :provisional && "text-ink-muted"
            ]}
          >
            {@readiness.status}
          </p>
        </div>

        <.data_table
          id="gstr1-filing-summary-rows"
          rows={filing_summary_rows(@derived, @active_invoices)}
          row_id={&"gstr1-filing-#{&1.key}"}
          min_width="min-w-[640px]"
          dense
        >
          <:col :let={row} label="Section">
            <span class="text-base-content font-medium">{row.label}</span>
          </:col>
          <:col :let={row} label="Invoices / notes" align="right">{row.documents}</:col>
          <:col :let={row} label="Taxable" align="right">{Helpers.rupees(row.taxable)}</:col>
          <:col :let={row} label="IGST" align="right">{Helpers.rupees(row.igst)}</:col>
          <:col :let={row} label="CGST" align="right">{Helpers.rupees(row.cgst)}</:col>
          <:col :let={row} label="SGST" align="right">{Helpers.rupees(row.sgst)}</:col>
        </.data_table>

        <section
          :if={@hsn_summary != []}
          id="gstr1-hsn-signoff"
          class="space-y-block"
        >
          <div class="flex flex-wrap items-center justify-between gap-3">
            <div class="space-y-1">
              <h4 class="text-base-content text-body font-semibold">HSN summary · Table 12</h4>
              <p class="text-ink-muted text-ui tabular-nums">
                {length(@hsn_summary)} HSN/rate {plural(length(@hsn_summary), "combination")} · {rupees(
                  @hsn_totals.taxable
                )} taxable · {rupees(@hsn_totals.tax)} output tax
              </p>
              <p
                :if={@novelty}
                id="gstr1-hsn-new-codes"
                class="text-ink-muted text-ui font-medium"
              >
                {@novelty.count} of {length(@hsn_summary)} codes are new for this client
              </p>
            </div>
            <.link
              :if={@hsn_issues != []}
              href="#gstr1-checks-before-filing"
              class="text-ui text-warning font-medium underline"
            >
              {length(@hsn_issues)} HSN {plural(length(@hsn_issues), "check")} in required work
            </.link>
          </div>
          <Workings.hsn_summary
            derived={@derived}
            invoices={@active_invoices}
            novelty_codes={@novelty_codes}
            rippled={@rippled}
            ripple_seq={@ripple_seq}
            expanded={@expanded_nodes}
          />
        </section>

        <section
          :if={@document_summary_rows != []}
          id="gstr1-document-summary"
          class="space-y-block"
        >
          <h4 class="text-base-content text-body font-semibold">Documents issued · Table 13</h4>
          <.data_table
            id="gstr1-document-summary-rows"
            rows={@document_summary_rows}
            row_id={&"gstr1-document-series-#{&1.id}"}
            min_width="min-w-[560px]"
            dense
          >
            <:col :let={row} label="Document kind">
              <span class="text-base-content font-medium">{row.kind}</span>
            </:col>
            <:col :let={row} label="From"><span class="font-mono">{row.from}</span></:col>
            <:col :let={row} label="To"><span class="font-mono">{row.to}</span></:col>
            <:col :let={row} label="Total" align="right">{row.total}</:col>
            <:col :let={row} label="Cancelled" align="right">{row.cancelled}</:col>
            <:col :let={row} label="Net issued" align="right">{row.net_issued}</:col>
          </.data_table>
        </section>
      </section>

      <%!-- Approval follows the proposed artifact and its statutory summaries.
            The register below is inspectable evidence, not a scroll ritual. --%>
      {render_slot(@actions)}

      <section id="gstr1-register" class="space-y-block">
        <h3 class="text-base-content text-body font-semibold">Sales document register</h3>
        <.invoice_table
          id="gstr1-invoices"
          rows={@invoices}
          visited={@visited}
          reviewed_invoice={@reviewed_invoice}
          issues_by_invoice={@issues_by_invoice}
          client={@client}
          period={@period}
        />
        <%!-- The register reads the extraction; the return files a
              recomputation. Naming both "Tax" is what let a reviewer approve
              one figure believing it was the other. --%>
        <p id="gstr1-register-basis" class="text-ink-subtle text-meta">
          These are the lines as extracted. The return files a per-rate recomputation of them,
          shown under Return workings — the two differ by a few paise, because CGST and SGST are
          aggregated and rounded once per rate bucket rather than per line.
        </p>
      </section>

      <section :if={@derived} id="gstr1-return" class="space-y-block">
        <h3 class="text-base-content text-body font-semibold">Return workings</h3>
        <Workings.workings_body
          derived={@derived}
          invoices={@active_invoices}
          diff={@diff}
          accepted={@accepted_diffs}
          locked={@r1_signoff != nil}
          rippled={@rippled}
          ripple_seq={@ripple_seq}
          expanded={@expanded_nodes}
        />
      </section>

      <section id="gstr1-source-documents" class="space-y-block">
        <h3 class="text-base-content text-body font-semibold">Source documents</h3>
        {render_slot(@source)}
      </section>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :visited, :any, default: MapSet.new()
  attr :reviewed_invoice, :string, default: nil
  attr :issues_by_invoice, :map, required: true
  attr :client, :map, required: true
  attr :period, :string, required: true

  defp invoice_table(assigns) do
    assigns =
      assign(assigns, :number_counts, Enum.frequencies_by(assigns.rows, & &1["invoice_number"]))

    ~H"""
    <.data_table
      id={@id}
      rows={@rows}
      row_id={
        fn invoice ->
          identity =
            if @number_counts[invoice["invoice_number"]] == 1,
              do: invoice["invoice_number"],
              else: invoice["id"]

          "gstr1-inv-#{identity}"
        end
      }
      row_click={
        fn invoice ->
          JS.patch(
            sales_review_path(
              @client,
              @period,
              invoice["id"],
              invoice_scope(@issues_by_invoice, invoice)
            )
          )
        end
      }
      row_class={
        fn invoice ->
          (invoice["id"] == @reviewed_invoice or
             invoice["invoice_number"] == @reviewed_invoice or
             invoice["pristine_inum"] == @reviewed_invoice) && "bg-primary/[0.04]"
        end
      }
      min_width="min-w-[760px]"
    >
      <:col :let={invoice} label="Document No">
        <span class={[
          "font-mono",
          (MapSet.member?(@visited, invoice["id"] || invoice["invoice_number"]) &&
             "text-primary/60") ||
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
      <:col :let={invoice} label="Recipient">
        <span class="text-ink-muted font-mono">
          {invoice["buyer_gstin"] || registration_label(invoice)}
        </span>
      </:col>
      <:col :let={invoice} label="POS">
        <span class="text-ink-muted font-mono">{invoice["place_of_supply"] || "—"}</span>
      </:col>
      <:col :let={invoice} label="Taxable" align="right">
        {rupees(Gstr1.extracted_totals(invoice).taxable)}
      </:col>
      <%!-- This invoice's tax reads three ways on this page: what the bill
            printed, the sum of the extracted lines, and the per-rate figure that
            reaches the return. All three were labelled "Tax". --%>
      <%!-- "Sum of extracted lines" said where the figure came from but not what
            it is, and it sits in the next column after Taxable — so ₹3,88,337
            beside ₹69,900.72 read as two takes on the taxable value. --%>
      <:col :let={invoice} label="Extracted GST" align="right">
        {rupees(Gstr1.extracted_totals(invoice).tax)}
      </:col>
      <:col :let={invoice} label="Status">
        <% state = invoice_state(@issues_by_invoice, invoice) %>
        <.badge :if={state} variant={state.variant}>{state.label}</.badge>
      </:col>
      <:col label="" align="right">
        <.icon name="hero-chevron-right-mini" class="text-ink-faint size-4" />
      </:col>
      <:empty>No sales documents were extracted for this month.</:empty>
    </.data_table>
    """
  end

  defp invoice_state(issues_by_invoice, invoice) do
    issues = Helpers.invoice_issues(issues_by_invoice, invoice)
    open = Enum.count(issues, &(&1["status"] == "open" and Issues.gating?(&1)))

    cond do
      Map.has_key?(invoice, "duplicate_copy") -> %{variant: "neutral", label: "Duplicate copy"}
      open > 0 -> %{variant: "warning", label: issues_clause(open)}
      issues != [] -> %{variant: "success", label: "Confirmed"}
      true -> nil
    end
  end

  defp track_title(%{filed_at: filed_at}, %{}) when not is_nil(filed_at), do: "GSTR-1 filed"
  defp track_title(_sales_month, %{}), do: "GSTR-1 approved"
  defp track_title(_sales_month, _signoff), do: "GSTR-1 draft"

  # One row per transaction section the return actually builds. Table 12 and
  # Table 13 have their own shapes below rather than being forced into this one.
  defp filing_summary_rows(derived, invoices) do
    [
      filing_summary_row(
        "b2b",
        "B2B regular",
        count_documents(derived, "b2b", "inv"),
        section_totals(derived, "b2b")
      ),
      filing_summary_row(
        "b2cs",
        "B2CS unregistered supplies",
        Enum.count(invoices, &(Gstr1.filing_table(&1) == "b2cs")),
        section_totals(derived, "b2cs")
      ),
      filing_summary_row(
        "b2cl",
        "B2CL large interstate supplies",
        count_documents(derived, "b2cl", "inv"),
        section_totals(derived, "b2cl")
      ),
      filing_summary_row(
        "cdnr",
        "9B registered credit and debit notes",
        count_documents(derived, "cdnr", "nt"),
        section_totals(derived, "cdnr")
      )
    ]
    |> Enum.reject(&(&1.documents == 0))
  end

  defp section_totals(derived, section) do
    sections = ~w(b2b b2cs b2cl cdnr)

    isolated =
      Enum.reduce(sections, derived, fn key, acc ->
        if key == section, do: acc, else: Map.put(acc, key, [])
      end)

    Values.filed_totals(isolated)
  end

  defp filing_summary_row(key, label, documents, totals) do
    %{
      key: key,
      label: label,
      documents: documents,
      taxable: totals.taxable,
      igst: totals.igst,
      cgst: totals.cgst,
      sgst: totals.sgst
    }
  end

  defp count_documents(derived, section, rows) do
    derived
    |> Map.get(section, [])
    |> Enum.reduce(0, &(length(&1[rows] || []) + &2))
  end

  defp document_summary_rows(nil), do: []

  defp document_summary_rows(derived) do
    derived
    |> get_in(["doc_issue", "doc_det"])
    |> List.wrap()
    |> Enum.flat_map(fn group ->
      group
      |> Map.get("docs", [])
      |> Enum.with_index(1)
      |> Enum.map(fn {series, index} ->
        %{
          id: "#{group["doc_num"]}-#{index}",
          kind: document_kind(group["doc_num"]),
          from: series["from"],
          to: series["to"],
          total: series["totnum"],
          cancelled: series["cancel"],
          net_issued: series["net_issue"]
        }
      end)
    end)
  end

  defp document_kind(1), do: "Tax invoices"
  defp document_kind(4), do: "Debit notes"
  defp document_kind(5), do: "Credit notes"
  defp document_kind(number), do: "Document type #{number}"

  defp document_mix_label(invoices) do
    counts = Enum.frequencies_by(invoices, &Gstr1.document_type/1)

    [
      count_label(counts["invoice"] || 0, "invoice"),
      count_label(counts["credit_note"] || 0, "credit note"),
      count_label(counts["debit_note"] || 0, "debit note")
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "0 invoices or notes"
      labels -> Enum.join(labels, " and ")
    end
  end

  defp count_label(0, _label), do: nil
  defp count_label(1, label), do: "1 #{label}"
  defp count_label(count, label), do: "#{count} #{label}s"

  defp hsn_issues(issues) do
    Enum.filter(issues, fn issue ->
      is_binary(issue["hsn_code"]) and
        issue["code"] in ~w(hsn_multiple_rates hsn_inferred_code rate_history_conflict statutory_rate_mismatch statutory_rate_review invalid_hsn_sac incomplete_hsn_sac)
    end)
  end

  # One concrete observation beside Table 12, with the code rows visible rather
  # than a generic count of the domain's advisory bucket.
  defp novelty(advisories) do
    case Enum.filter(advisories, &(&1["code"] == "hsn_new_code")) do
      [] ->
        nil

      issues ->
        codes = issues |> Enum.map(& &1["hsn_code"]) |> Enum.uniq() |> Enum.sort()

        %{
          count: length(codes),
          codes: codes
        }
    end
  end

  # Every code the issue covers, not just the first. Collapsing per-line findings
  # into one card left this reading `hsn_code` alone, so an invoice with two bad
  # codes cleared its check once the rows for the first were expanded — the
  # second was never rendered and nobody looked at it. Before the collapse that
  # took two separate reviews.
  defp hsn_reviewed?(issue, invoices, expanded_nodes) do
    case Enum.flat_map(hsn_codes(issue), &Workings.hsn_node_ids(invoices, &1)) do
      [] -> false
      nodes -> Enum.all?(nodes, &MapSet.member?(expanded_nodes, &1))
    end
  end

  # The fallback is load-bearing: `rate_history.ex` and `multiple_rate_issues/1`
  # emit single-code issues that carry no `hsn_codes` at all.
  defp hsn_codes(issue), do: issue["hsn_codes"] || List.wrap(issue["hsn_code"])

  defp hsn_totals(rows) do
    Enum.reduce(rows, %{taxable: 0.0, tax: 0.0}, fn row, totals ->
      %{
        taxable: totals.taxable + (row["txval"] || 0),
        tax: totals.tax + (row["iamt"] || 0) + (row["camt"] || 0) + (row["samt"] || 0)
      }
    end)
  end

  defp sales_review_path(client, period, source_id, scope, focus \\ nil) do
    params =
      %{"item" => source_id, "scope" => to_string(scope), "focus" => focus}
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    "/gst/#{client.id}/#{period}/review/sales?" <> URI.encode_query(params)
  end

  defp registration_label(invoice) do
    case Gstr1.recipient_registration(invoice) do
      "unregistered" -> "Unregistered"
      "unknown" -> "Registration unknown"
      _registered -> "—"
    end
  end

  defp invoice_scope(issues_by_invoice, invoice) do
    actionable? =
      issues_by_invoice
      |> Helpers.invoice_issues(invoice)
      |> Enum.any?(fn issue ->
        issue["status"] == "open" and
          Issues.resolution_kind(issue) in [:decision, :correction, :confirmation]
      end)

    if actionable?, do: :needs_you, else: :all
  end

  defp issues_clause(0), do: "Ready"
  defp issues_clause(1), do: "1 to answer"
  defp issues_clause(n), do: "#{n} to answer"

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"

  defp rupees(amount), do: Helpers.rupees(amount)
end
