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
  attr :invoices, :list, required: true
  attr :active_invoices, :list, required: true
  attr :open_issue_count, :integer, required: true
  attr :account, :map, required: true
  attr :completeness, :atom, required: true
  attr :confirmation, :any, default: nil
  attr :r1_signoff, :any, default: nil
  attr :month_issues, :list, required: true
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
      # The completeness questions gate like anything else, but they are one
      # block of yes/no/don't-know rather than six rows in a list of defects —
      # nothing is asserted to be wrong with the bills we hold.
      |> assign(
        :required_issues,
        Enum.reject(assigns.account.issues.required, &completeness?/1)
      )
      |> assign(
        :completeness_questions,
        completeness_questions(assigns.month_issues)
      )
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
          "border-base-300 p-block rounded-box border",
          Workings.ripple_class(@rippled, @ripple_seq, "gstr1-account")
        ]}
      >
        <div class="flex flex-wrap items-start justify-between gap-4">
          <div class="space-y-related">
            <div class="flex flex-wrap items-center gap-2">
              <h2 class="text-base-content text-h4 font-semibold">GSTR-1</h2>
              <.badge variant={@verdict.variant}>{@verdict.label}</.badge>
            </div>
            <p class="text-body text-ink-muted">{@verdict.copy}</p>
          </div>
          <%!-- The card above already asserts the tally; the button says where
                it goes, not how many again. --%>
          <.button
            :if={@open_issue_count > 0}
            id="gstr1-review-required"
            href="#gstr1-checks-before-filing"
            variant="primary"
            size="sm"
          >
            Take them one by one
          </.button>
        </div>
        <dl class="gap-block mt-block grid sm:grid-cols-3">
          <div>
            <dt class="text-ink-subtle text-label font-semibold uppercase">Extracted invoices</dt>
            <dd class="font-display text-base-content text-lead tabular-nums">
              {@account.extraction.documents}
            </dd>
          </div>
          <div>
            <dt class="text-ink-subtle text-label font-semibold uppercase">Taxable value</dt>
            <dd class="font-display text-base-content text-lead tabular-nums">
              {Helpers.rupees(@account.draft.totals.taxable)}
            </dd>
          </div>
          <div>
            <dt class="text-ink-subtle text-label font-semibold uppercase">Output tax</dt>
            <dd class="font-display text-base-content text-lead tabular-nums">
              {Helpers.rupees(@account.draft.totals.tax)}
            </dd>
          </div>
        </dl>
      </section>

      {render_slot(@actions)}

      <%!-- What the pile cannot tell us about itself.

            Everything in the completeness block above is internal consistency —
            files received, pages read, sequence gaps. One perfectly read file
            can still be half a month, and no amount of internal agreement can
            reveal a credit note that was issued and never sent. Somebody has to
            answer, per question, because each yes routes somewhere different. --%>
      <section
        :if={@completeness_questions != []}
        id="gstr1-completeness-attestation"
        class="space-y-block"
      >
        <div class="flex items-center justify-between gap-3">
          <h3 class="text-base-content text-body font-semibold">What we can't see from the pile</h3>
          <span class="text-ink-subtle text-meta">
            {Enum.count(@completeness_questions, &is_nil(&1.answer))} unanswered
          </span>
        </div>
        <div class="border-base-300 divide-base-300 rounded-box divide-y border">
          <div
            :for={q <- @completeness_questions}
            id={"gstr1-attest-#{q.key}"}
            class="gap-related flex flex-wrap items-center px-4 py-3"
          >
            <p class="text-base-content text-ui min-w-0 flex-1">{q.question}</p>
            <div :if={is_nil(q.answer) and is_nil(@r1_signoff)} class="flex gap-1.5">
              <.button
                variant="outline"
                size="xs"
                phx-click="attest-completeness"
                phx-value-target={q.target}
                phx-value-answer="no"
              >
                No
              </.button>
              <.button
                variant="outline"
                size="xs"
                phx-click="attest-completeness"
                phx-value-target={q.target}
                phx-value-answer="yes"
              >
                Yes
              </.button>
              <%!-- Never force a "no" to proceed. "I haven't checked" is the
                    honest answer most of the time, and it routes to the client
                    rather than into the filing. --%>
              <.button
                variant="ghost"
                size="xs"
                phx-click="attest-completeness"
                phx-value-target={q.target}
                phx-value-answer="unknown"
              >
                Don't know
              </.button>
            </div>
            <div :if={q.answer} class="flex items-center gap-2">
              <span class={[
                "text-meta font-medium",
                (q.answer == "no" && "text-ink-subtle") || "text-warning"
              ]}>
                {attestation_note(q)}
              </span>
              <.button
                :if={is_nil(@r1_signoff)}
                variant="ghost"
                size="xs"
                phx-click="undo"
                phx-value-target={q.target}
              >
                Undo
              </.button>
            </div>
          </div>
        </div>
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
              phx-value-code={issue["hsn_code"]}
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
              phx-click="review-sales-issue"
              phx-value-source={issue["source_id"]}
              phx-value-target={SalesWorkings.issue_key(issue)}
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
              phx-click="review-sales-issue"
              phx-value-source={issue["source_id"]}
              phx-value-target={SalesWorkings.issue_key(issue)}
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
          <div class="flex flex-wrap items-center gap-2">
            <.badge variant={completeness_variant(@completeness)}>
              {completeness_label(@completeness)}
            </.badge>
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
        </div>

        <div class="border-base-300 rounded-box grid gap-4 border p-4 sm:grid-cols-2 lg:grid-cols-4">
          <.control_stat label="Source files received" value={@account.source.files} />
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
                phx-click="review-sales-issue"
                phx-value-source={first_reviewable_cause(row.causes).source_id}
                phx-value-target={first_reviewable_cause(row.causes).target}
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
            <.control_stat
              label="Difference from invoice register"
              value={rupees(@hsn_totals.tax - @account.extraction.totals.tax)}
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
        <%!-- Before anyone answers, the capability statement is all this page
              can honestly say. Once they have, it names what was actually
              confirmed absent — an assertion with a person behind it, not a
              claim the engine invented from an empty table. --%>
        <p
          :if={confirmed_absent(@completeness_questions) != []}
          id="gstr1-filing-confirmed-absent"
          class="text-ink-subtle text-meta"
        >
          Confirmed absent this month: {confirmed_absent(@completeness_questions)
          |> Enum.map_join(", ", & &1.noun)}.
        </p>
        <p id="gstr1-filing-capability" class="text-ink-subtle text-meta">
          This return files B2B invoices. A credit note, export, SEZ, reverse-charge or B2C bill
          stops the month rather than being filed as an ordinary invoice.
        </p>
      </section>

      <section id="gstr1-register" class="space-y-block">
        <h3 class="text-base-content text-body font-semibold">Invoice register</h3>
        <.invoice_table
          id="gstr1-invoices"
          rows={@invoices}
          visited={@visited}
          reviewed_invoice={@reviewed_invoice}
          issues_by_invoice={@issues_by_invoice}
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
          identifier =
            if @number_counts[invoice["invoice_number"]] == 1,
              do: invoice["invoice_number"],
              else: invoice["id"]

          JS.push("select-invoice", value: %{inum: identifier})
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
      <:col :let={invoice} label="Sum of extracted lines" align="right">
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

  defp control_stat(assigns) do
    ~H"""
    <div>
      <dt class="text-ink-subtle text-label font-semibold uppercase">{@label}</dt>
      <dd class="text-base-content text-body mt-1 font-medium tabular-nums">{@value}</dd>
    </div>
    """
  end

  defp verdict_state(%{r1_signoff: %{}, sales_month: %{filed_at: filed_at}})
       when not is_nil(filed_at),
       do: %{
         variant: "neutral",
         label: "Filed",
         copy: "The approved return is on the GST portal."
       }

  defp verdict_state(%{r1_signoff: %{}}),
    do: %{
      variant: "success",
      label: "Approved",
      copy: "The approved draft is frozen and ready for portal filing."
    }

  defp verdict_state(%{account: %{issues: %{required_count: count} = issues}}) when count > 0,
    do: %{
      variant: "error",
      label: "Blocked",
      copy: verdict_copy(issues)
    }

  defp verdict_state(%{completeness: completeness}) when completeness != :complete,
    do: %{
      variant: "error",
      label: "Blocked",
      copy: "Approval waits for current client confirmation."
    }

  defp verdict_state(_assigns),
    do: %{
      variant: "success",
      label: "Ready for approval",
      copy: "All checks are resolved and supplied sales documents are accounted for."
    }

  defp completeness?(%{"code" => "completeness_unconfirmed"}), do: true
  defp completeness?(_issue), do: false

  # Every question, in the order the domain asks them, carrying whatever answer
  # has been given. An answered "no" leaves no issue behind, so the answered
  # ones are reconstructed from the question list rather than from the issues.
  defp completeness_questions(issues) do
    asked =
      issues
      |> Enum.filter(&completeness?/1)
      |> Map.new(&{&1["attestation_key"], &1})

    Enum.flat_map(SalesWorkings.completeness_questions(), fn q ->
      case asked[q.key] do
        nil ->
          []

        issue ->
          [%{key: q.key, question: q.question, target: issue["target"], answer: issue["answer"]}]
      end
    end)
  end

  # Only what somebody actually said "no" to. A question answered "yes" or left
  # unknown is not an absence anyone confirmed, and listing it here would put an
  # assertion in a reviewer's mouth.
  defp confirmed_absent(questions) do
    nouns = %{
      "credit_or_debit_notes" => "credit and debit notes",
      "exports" => "exports",
      "sez_supplies" => "SEZ supplies",
      "b2c_supplies" => "B2C supplies",
      "cancelled_documents" => "cancellations",
      "additional_series" => "any further invoice series"
    }

    for q <- questions, q.answer == "no", do: %{noun: nouns[q.key]}
  end

  defp attestation_note(%{answer: "no"}), do: "No"
  defp attestation_note(%{answer: "yes"}), do: "Yes — see the blocker below"
  defp attestation_note(%{answer: "unknown"}), do: "Asked the client"
  defp attestation_note(_q), do: nil

  defp verdict_copy(%{advisory_count: 0} = issues),
    do: "#{Helpers.work_clause(issues.by_kind)} before this can be approved."

  defp verdict_copy(issues) do
    "#{Helpers.work_clause(issues.by_kind, issues.advisory_count)} — the advisories are context, " <>
      "the rest hold the filing."
  end

  defp draft_label(%{r1_signoff: %{}}), do: "Approved draft"

  defp draft_label(%{account: %{issues: %{required: issues}}, completeness: :complete}) do
    if SalesWorkings.reviewable?(issues), do: "Draft for approval", else: "Proposed after fixes"
  end

  defp draft_label(_assigns), do: "Proposed after fixes"

  defp completeness_variant(:complete), do: "success"
  defp completeness_variant(:client_no), do: "warning"
  defp completeness_variant(:stale), do: "warning"
  defp completeness_variant(:open), do: "neutral"

  defp completeness_label(:complete), do: "Client confirmed"
  defp completeness_label(:client_no), do: "More documents coming"
  defp completeness_label(:stale), do: "Confirmation stale"
  defp completeness_label(:open), do: "Awaiting client confirmation"

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

  defp hsn_reviewed?(issue, invoices, expanded_nodes) do
    case Workings.hsn_node_ids(invoices, issue["hsn_code"]) do
      [] -> false
      nodes -> Enum.all?(nodes, &MapSet.member?(expanded_nodes, &1))
    end
  end

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

  defp issues_clause(0), do: "Ready"
  defp issues_clause(1), do: "1 to answer"
  defp issues_clause(n), do: "#{n} to answer"

  defp verb(1), do: "is"
  defp verb(_count), do: "are"

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"

  defp rupees(amount), do: Helpers.rupees(amount)
end
