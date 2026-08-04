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
  attr :completeness, :atom, required: true
  attr :confirmation, :any, default: nil
  attr :r1_signoff, :any, default: nil
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
      |> assign(:series, assigns.account.extraction.series)
      |> assign(:required_issues, assigns.account.issues.required)
      |> assign(:verdict, verdict_state(assigns))
      |> assign(:draft_label, draft_label(assigns))
      |> assign(:reconciliation_rows, reconciliation_rows(assigns.account))
      |> assign(:hsn_summary, Gstr1.hsn_summary(assigns.active_invoices))
      |> assign(:hsn_issues, hsn_issues(assigns.account.issues.required))
      |> assign(:novelty, novelty(assigns.account.issues.advisory))
      |> assign(:other_advisories, other_advisories(assigns.account.issues.advisory))
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
              class="text-body text-ink-muted"
            >
              {@verdict.copy}
            </p>
            <.link
              :if={@account.issues.advisory_count > 0}
              href="#gstr1-advisories"
              class="text-ink-subtle text-meta inline-block whitespace-nowrap"
            >
              {@account.issues.advisory_count} {Helpers.pluralise(
                @account.issues.advisory_count,
                "advisory"
              )}
            </.link>
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
            {@account.draft.documents} {plural(@account.draft.documents, "invoice")} in draft
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
        <div class="flex items-center justify-between gap-3">
          <h3 class="text-base-content text-body font-semibold">Before filing</h3>
          <span id="gstr1-required-clause" class="text-error text-ui font-medium">
            {Helpers.work_clause(@account.issues.by_kind)}
          </span>
        </div>
        <%!-- A blocker is a gap in this engine, not a defect in the client's
              bills, and nothing on this page can clear one. Saying so names the
              move that is actually available instead of leaving the month
              parked against a wall. --%>
        <p
          :if={Map.get(@account.issues.by_kind, :blocked, 0) > 0}
          id="gstr1-blocked-next-move"
          class="bg-error/5 border-error/30 rounded-box text-base-content text-body border px-4 py-3"
        >
          Nila files B2B invoices only, so it cannot build this month's return. File {Nila.Formatters.period_label(
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
            <.badge variant={Helpers.severity_variant(issue["level"])}>
              {issue_label(issue["code"])}
            </.badge>
            <div class="min-w-0 flex-1">
              <p :if={issue["invoice"]} class="text-base-content text-ui font-medium">
                Invoice {issue["invoice"]}
              </p>
              <p class="text-body text-ink-muted">{issue["message"]}</p>
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
            <%!-- Two exits, because a yes-only answer to "does cess apply" is a dead end. --%>
            <div :if={issue["code"] == "cess_not_evaluated"} class="flex flex-wrap gap-2">
              <.button
                id="gstr1-cess-none"
                variant="outline"
                size="xs"
                phx-click="confirm_issue"
                phx-value-target={SalesWorkings.issue_key(issue)}
                phx-value-answer="no_cess"
              >
                No cess applies
              </.button>
              <.button
                id="gstr1-cess-applies"
                variant="outline"
                size="xs"
                phx-click="confirm_issue"
                phx-value-target={SalesWorkings.issue_key(issue)}
                phx-value-answer="cess_applies"
              >
                Cess applies
              </.button>
            </div>
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
                  issue["code"] != "cess_not_evaluated" and
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

      <%!-- Context, not outstanding work: one grouped block, no dismissal, and
            approval never asks whether anyone opened it. Seven rows of
            low-priority novelty is quieter spam, still spam. --%>
      <section
        :if={@novelty != nil or @other_advisories != []}
        id="gstr1-advisories"
        class="space-y-related"
      >
        <details :if={@novelty} id="gstr1-advisory-hsn-new" class="border-base-300 rounded-box border">
          <summary class="text-base-content text-ui cursor-pointer px-4 py-3 font-medium">
            {@novelty.headline}
            <span class="text-ink-subtle text-meta mt-1 block font-mono font-normal">
              {Enum.join(@novelty.codes, " · ")}
            </span>
          </summary>
          <.data_table id="gstr1-advisory-hsn-rows" rows={@novelty.rows} dense>
            <:col :let={row} label="HSN / SAC"><span class="font-mono">{row.code}</span></:col>
            <:col :let={row} label="Description">{row.description}</:col>
            <:col :let={row} label="Rate" align="right">{row.rates}</:col>
            <:col :let={row} label="Taxable value" align="right">{rupees(row.taxable)}</:col>
            <:col :let={row} label="Invoices">{row.invoices}</:col>
            <:col :let={row} label="Read from">{row.provenance}</:col>
          </.data_table>
          <div class="px-4 py-3">
            <.button href="#gstr1-hsn-signoff" variant="outline" size="xs">
              Review HSN summary
            </.button>
          </div>
        </details>
        <p
          :for={issue <- @other_advisories}
          id={"gstr1-advisory-#{:erlang.phash2(SalesWorkings.issue_key(issue))}"}
          class="border-base-300 rounded-box text-body text-ink-muted border px-4 py-3"
        >
          {issue["message"]}
        </p>
      </section>

      <section id="gstr1-completeness" class="space-y-block">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <h3 class="text-base-content text-body font-semibold">Completeness and reconciliation</h3>
          <%!-- No status pill. It restated `confirmation_note/2` at the foot of
                this same section in two words, and the two words were the worse
                copy: "Awaiting client confirmation" names a wait without saying
                who is being waited on or through which channel. --%>
          <.button
            :if={@completeness != :complete and is_nil(@r1_signoff)}
            id="gstr1-record-confirmation"
            variant="outline"
            size="xs"
            phx-click="open-completeness-override"
          >
            Record client confirmation
          </.button>
        </div>

        <%!-- The file count is read live off today's dumps while the documents
              beside it can come out of a frozen snapshot, so "0 files received"
              can sit next to "12 documents extracted" — a pair that cannot both
              be true. A count that cannot be true is a count we do not have: a
              month reconciled from a backfill or an import never had a file
              pass through intake. Same treatment the purchase track already
              gives it. --%>
        <div class="border-base-300 rounded-box grid gap-4 border p-4 sm:grid-cols-2 lg:grid-cols-4">
          <.control_stat
            label="Source files received"
            value={@account.source.files}
            unknown={@account.source.files == 0 and @account.extraction.documents > 0}
            unknown_note="not recorded for this month"
          />
          <.control_stat
            :if={@account.source.pages_read}
            label="Invoice pages read"
            value={@account.source.pages_read}
          />
          <.control_stat label="Documents extracted" value={@account.extraction.documents} />
          <.control_stat
            label="Unique invoice numbers"
            value={@account.extraction.unique_invoice_numbers}
          />
          <.control_stat
            label="Duplicate documents unresolved"
            value={@account.extraction.unresolved_duplicates}
          />
          <.control_stat label="Documents included in draft" value={@account.draft.documents} />
          <.control_stat
            label="Sequence gaps"
            value={if(@series, do: length(@series.missing), else: "Not checked")}
          />
          <.control_stat
            :if={@account.extraction.duplicate_copies > 0}
            label="Duplicate documents excluded"
            value={@account.extraction.duplicate_copies}
          />
          <.control_stat label="Cess" value={cess_label(@account.cess)} />
        </div>

        <.data_table id="gstr1-reconciliation" rows={@reconciliation_rows} dense>
          <:col :let={row} label="Component">{row.label}</:col>
          <:col :let={row} label="As printed" align="right">{row.printed}</:col>
          <:col :let={row} label={@draft_label} align="right">{row.proposed}</:col>
          <:col :let={row} label="Review">
            <div :if={row.changed} class="flex flex-wrap items-center gap-2">
              <span class="text-ink-muted text-ui">
                {cause_label(row.causes)}
              </span>
              <.button
                :if={first_reviewable_cause(row.causes)}
                variant="ghost"
                size="xs"
                patch={
                  sales_review_path(
                    @client,
                    @period,
                    first_reviewable_cause(row.causes).source_id,
                    :needs_you,
                    first_reviewable_cause(row.causes).target
                  )
                }
              >
                Review
              </.button>
            </div>
          </:col>
        </.data_table>

        <section id="gstr1-hsn-signoff" class="border-base-300 rounded-box space-y-block border p-4">
          <div class="flex flex-wrap items-center justify-between gap-3">
            <h4 class="text-base-content text-body font-semibold">Table 12 · HSN summary</h4>
            <.badge variant={if @hsn_issues == [], do: "success", else: "warning"}>
              {if @hsn_issues == [],
                do: "Reconciled",
                else: "#{length(@hsn_issues)} #{plural(length(@hsn_issues), "check")}"}
            </.badge>
          </div>
          <dl class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            <.control_stat
              label="HSN/rate combinations"
              value={length(@hsn_summary)}
            />
            <.control_stat label="Taxable value" value={rupees(@hsn_totals.taxable)} />
            <.control_stat label="Output tax" value={rupees(@hsn_totals.tax)} />
            <%!-- A non-zero difference under a badge reading "Reconciled" is a
                  contradiction unless the page says why it is expected. The
                  register sums tax per line; the return recomputes it once per
                  rate bucket. Two paragraphs elsewhere explain this — the tile
                  that actually prints the paise did not. --%>
            <.control_stat
              label="Difference from invoice register"
              value={rupees(@hsn_totals.tax - @account.extraction.totals.tax)}
              note={rounding_note(@hsn_totals.tax - @account.extraction.totals.tax)}
            />
          </dl>
          <%!-- The issues themselves live in "Before filing", once. This card
                kept a second copy of the same list ~600px away, with different
                buttons; its job is the totals and whether they reconcile. --%>
          <p :if={@hsn_issues != []} class="text-ink-muted text-ui">
            <.link href="#gstr1-checks-before-filing" class="underline">
              {length(@hsn_issues)} of the checks before filing {verb(length(@hsn_issues))} these rows
            </.link>
          </p>
        </section>

        <p class="text-ink-muted text-ui">{confirmation_note(@confirmation, @completeness)}</p>
      </section>

      <section class="space-y-block">
        <h3 class="text-base-content text-body font-semibold">Source documents</h3>
        {render_slot(@source)}
      </section>

      <%!-- The object being approved, which this page never actually showed.
            One row, because `derive/2` emits b2b, hsn and doc_issue and nothing
            else — printing "Credit/debit notes: none" would be an assertion
            nobody made and the engine cannot check. --%>
      <section :if={@derived} id="gstr1-filing-summary" class="space-y-block">
        <h3 class="text-base-content text-body font-semibold">What this return files</h3>
        <.data_table
          id="gstr1-filing-summary-rows"
          rows={filing_summary_rows(@account, @derived)}
          row_id={&"gstr1-filing-#{&1.key}"}
          min_width="min-w-[640px]"
          dense
        >
          <:col :let={row} label="Section">
            <span class="text-base-content font-medium">{row.label}</span>
          </:col>
          <:col :let={row} label="Documents" align="right">{row.documents}</:col>
          <:col :let={row} label="Taxable" align="right">{Helpers.rupees(row.taxable)}</:col>
          <:col :let={row} label="IGST" align="right">{Helpers.rupees(row.igst)}</:col>
          <:col :let={row} label="CGST" align="right">{Helpers.rupees(row.cgst)}</:col>
          <:col :let={row} label="SGST" align="right">{Helpers.rupees(row.sgst)}</:col>
          <:col :let={row} label="Status">
            <span class={["text-meta", row.blocked? && "text-error"]}>{row.status}</span>
          </:col>
        </.data_table>
        <p id="gstr1-filing-capability" class="text-ink-subtle text-meta">
          This return files B2B invoices. A credit note, export, SEZ, reverse-charge or B2C bill
          stops the month rather than being filed as an ordinary invoice.
        </p>
      </section>

      <%!-- Directly under the return it approves. This used to render ~370
            lines higher, above the checks and the source documents, so the
            summary of what was actually being filed sat below the button that
            filed it and a reviewer taking the normal path never saw it. --%>
      {render_slot(@actions)}

      <section id="gstr1-register" class="space-y-block">
        <h3 class="text-base-content text-body font-semibold">Invoice register</h3>
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
      <:col :let={invoice} label="Inv No">
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
      <:col :let={invoice} label="Buyer GSTIN">
        <span class="text-ink-muted font-mono">{invoice["buyer_gstin"] || "—"}</span>
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
      <:col :let={invoice} label="Tax · sum of extracted lines" align="right">
        {rupees(Gstr1.extracted_totals(invoice).tax)}
      </:col>
      <:col :let={invoice} label="Status">
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
    open = Enum.count(issues, &(&1["status"] == "open" and Issues.gating?(&1)))

    cond do
      Map.has_key?(invoice, "duplicate_copy") -> %{variant: "neutral", label: "Duplicate copy"}
      open > 0 -> %{variant: "warning", label: issues_clause(open)}
      issues != [] -> %{variant: "success", label: "Confirmed"}
      true -> nil
    end
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :note, :string, default: nil
  attr :unknown, :boolean, default: false
  attr :unknown_note, :string, default: nil

  defp control_stat(assigns) do
    ~H"""
    <div>
      <dt class="text-ink-subtle text-label font-semibold uppercase">{@label}</dt>
      <dd
        :if={not @unknown}
        class="text-base-content text-body mt-1 font-medium tabular-nums"
      >
        {@value}
      </dd>
      <dd :if={@unknown} class="text-body text-ink-subtle mt-1 font-medium">
        — <span class="text-meta">{@unknown_note}</span>
      </dd>
      <p :if={@note} class="text-ink-subtle text-meta mt-1">{@note}</p>
    </div>
    """
  end

  defp rounding_note(difference) when difference == 0, do: nil

  defp rounding_note(_difference),
    do: "Per-rate rounding, not a discrepancy — the return rounds once per rate bucket."

  defp track_title(%{filed_at: filed_at}, %{}) when not is_nil(filed_at), do: "GSTR-1 filed"
  defp track_title(_sales_month, %{}), do: "GSTR-1 approved"
  defp track_title(_sales_month, _signoff), do: "GSTR-1 draft"

  defp verdict_state(%{r1_signoff: %{}, sales_month: %{filed_at: filed_at}})
       when not is_nil(filed_at),
       do: %{copy: "The approved return is on the GST portal."}

  defp verdict_state(%{r1_signoff: %{}}),
    do: %{copy: "The approved draft is frozen and ready for portal filing."}

  defp verdict_state(%{completeness: completeness}) when completeness != :complete,
    do: %{copy: "Approval waits for current client confirmation."}

  defp verdict_state(_assigns),
    do: %{copy: "Ready for approval. All required checks are resolved."}

  defp draft_label(%{r1_signoff: %{}}), do: "Approved draft"

  defp draft_label(%{account: %{issues: %{required: issues}}, completeness: :complete}) do
    if SalesWorkings.reviewable?(issues), do: "Draft for approval", else: "Proposed after fixes"
  end

  defp draft_label(_assigns), do: "Proposed after fixes"

  # Every state the pill carried, in a sentence that says who and through which
  # channel. This is now the only place the section states it.
  defp confirmation_note(nil, _status),
    do: "Awaiting a period-specific WhatsApp confirmation from the client."

  defp confirmation_note(confirmation, :stale),
    do:
      "Confirmation recorded #{format_display_datetime(confirmation.inserted_at)}, but later or unresolved sales intake requires confirmation again."

  defp confirmation_note(%{decision: "client_no"} = confirmation, _status),
    do:
      "Client said more documents are coming · #{format_display_datetime(confirmation.inserted_at)}"

  defp confirmation_note(%{decision: "senior_override"} = confirmation, _status) do
    actor = confirmation.actor_user && confirmation.actor_user.name

    "Overridden by #{actor || "a senior"} · #{confirmation.reason} · #{format_display_datetime(confirmation.inserted_at)}"
  end

  defp confirmation_note(confirmation, _status),
    do:
      "Client confirmed all sales documents were sent via WhatsApp · #{format_display_datetime(confirmation.inserted_at)}"

  # One row per section the return actually builds. The status is the work still
  # standing against it, in the same vocabulary the rest of the page uses.
  defp filing_summary_rows(account, derived) do
    totals = Values.filed_totals(derived)
    by_kind = account.issues.by_kind

    [
      %{
        key: "b2b",
        label: "B2B regular",
        documents: account.draft.documents,
        taxable: totals.taxable,
        igst: totals.igst,
        cgst: totals.cgst,
        sgst: totals.sgst,
        blocked?: Map.get(by_kind, :blocked, 0) > 0,
        status: filing_status(account)
      }
    ]
  end

  defp filing_status(account) do
    cond do
      Map.get(account.issues.by_kind, :blocked, 0) > 0 -> "Held by a blocker"
      account.issues.required_count > 0 -> Helpers.work_clause(account.issues.by_kind)
      true -> "Ready"
    end
  end

  # A snapshot frozen before the printed projection existed has no "as printed"
  # side, and inventing one from the current invoices would let a signed
  # month's reconciliation drift after signature. The draft column is frozen and
  # still true, so it stands alone and the comparison declines to answer.
  defp reconciliation_rows(%{printed: %{recorded?: false}} = account) do
    [
      unrecorded_row("Documents", account.draft.documents),
      unrecorded_row("Taxable value", Helpers.rupees(account.draft.totals[:taxable])),
      unrecorded_row("IGST", Helpers.rupees(account.draft.totals[:igst])),
      unrecorded_row("CGST", Helpers.rupees(account.draft.totals[:cgst])),
      unrecorded_row("SGST", Helpers.rupees(account.draft.totals[:sgst])),
      unrecorded_row("Output tax", Helpers.rupees(account.draft.totals[:tax]))
    ]
  end

  defp reconciliation_rows(account) do
    [
      reconciliation_row(
        "Documents",
        account.printed.documents,
        account.draft.documents,
        account.draft.documents - account.printed.documents,
        [],
        :count
      ),
      money_row("Taxable value", account, :taxable),
      money_row("IGST", account, :igst),
      money_row("CGST", account, :cgst),
      money_row("SGST", account, :sgst),
      money_row("Output tax", account, :tax)
    ]
  end

  defp money_row(label, account, key) do
    reconciliation_row(
      label,
      account.printed.totals[key],
      account.draft.totals[key],
      account.differences[key],
      account.causes[key],
      :money
    )
  end

  defp reconciliation_row(label, printed, proposed, difference, causes, :count) do
    %{
      label: label,
      printed: printed,
      proposed: proposed,
      changed: difference != 0,
      causes: causes
    }
  end

  defp reconciliation_row(label, printed, proposed, difference, causes, :money) do
    %{
      label: label,
      printed: Helpers.rupees(printed),
      proposed: Helpers.rupees(proposed),
      changed: abs(difference) >= 0.01,
      causes: causes
    }
  end

  # `changed: false` because nothing is being asserted to have changed — there is
  # no comparison, so there is no review prompt to offer either.
  defp unrecorded_row(label, proposed),
    do: %{label: label, printed: "not recorded", proposed: proposed, changed: false, causes: []}

  defp cause_label([]), do: "Review the affected filing checks"

  defp cause_label(causes) do
    invoices = causes |> Enum.flat_map(& &1.invoices) |> Enum.uniq()
    "Caused by #{plural(length(invoices), "invoice")} #{Enum.join(invoices, ", ")}"
  end

  defp first_reviewable_cause(causes),
    do: Enum.find(causes, &is_binary(&1.source_id))

  defp hsn_issues(issues) do
    Enum.filter(issues, fn issue ->
      is_binary(issue["hsn_code"]) and
        issue["code"] in ~w(hsn_multiple_rates hsn_inferred_code rate_history_conflict statutory_rate_mismatch statutory_rate_review invalid_hsn_sac incomplete_hsn_sac)
    end)
  end

  # One block for the whole of "we have not seen these codes before", expandable
  # to what a reviewer would want if he decided to look: what the code is, at
  # what rate, on how much, from which bills, and whether anyone read it off one.
  defp novelty(advisories) do
    case Enum.filter(advisories, &(&1["code"] == "hsn_new_code")) do
      [] ->
        nil

      issues ->
        codes = issues |> Enum.map(& &1["hsn_code"]) |> Enum.uniq() |> Enum.sort()

        %{
          headline:
            "#{length(codes)} HSN/SAC #{plural(length(codes), "code")} #{verb(length(codes))} new for this client",
          codes: codes,
          rows: Enum.map(issues, &novelty_row/1)
        }
    end
  end

  defp novelty_row(issue) do
    %{
      code: issue["hsn_code"],
      description: issue["hsn_description"] || "—",
      rates: issue["hsn_rates"] |> List.wrap() |> Enum.map_join(" / ", &Helpers.percent/1),
      taxable: issue["hsn_taxable"],
      invoices: issue["hsn_invoices"] |> List.wrap() |> Enum.join(", "),
      provenance: if(issue["hsn_inferred"], do: "Inferred", else: "Printed on the bill")
    }
  end

  defp other_advisories(advisories),
    do: Enum.reject(advisories, &(&1["code"] == "hsn_new_code"))

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

  defp cess_label(:checked_none), do: "Checked · none found"
  defp cess_label(:not_evaluated), do: "Not checked · awaiting your answer"
  defp cess_label(:unsupported), do: "Applies · this return cannot carry it"

  defp sales_review_path(client, period, source_id, scope, focus \\ nil) do
    params =
      %{"item" => source_id, "scope" => to_string(scope), "focus" => focus}
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    "/gst/#{client.id}/#{period}/review/sales?" <> URI.encode_query(params)
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

  defp verb(1), do: "is"
  defp verb(_count), do: "are"

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"

  defp rupees(amount), do: Helpers.rupees(amount)
end
