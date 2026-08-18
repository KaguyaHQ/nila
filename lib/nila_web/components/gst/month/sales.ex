defmodule NilaWeb.Components.Gst.Month.Sales do
  use NilaWeb, :html

  @moduledoc "The Sales and GSTR-1 workpaper."

  alias Nila.Gst.Issues
  alias Nila.Gst.Sales.Gstr1
  alias Nila.Gst.Sales.Values
  alias Nila.Gst.Sales.Workings, as: SalesWorkings
  alias NilaWeb.Components.Gst.Month.Helpers
  alias NilaWeb.Components.Gst.Month.Workings
  alias NilaWeb.Components.Gst.Month.Workpaper

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
  attr :open_folds, :any, default: MapSet.new()
  attr :register_rows, :list, required: true
  attr :register_form, :any, required: true
  attr :register_filter, :atom, required: true
  attr :review, :any, required: true
  attr :decisions, :map, default: %{}
  attr :change, :any, default: nil
  slot :source
  slot :primary_action
  slot :actions

  def sales_section(%{sales_month: nil} = assigns) do
    ~H"""
    """
  end

  def sales_section(assigns) do
    required_issues = assigns.account.issues.required
    hsn_summary = Gstr1.hsn_summary(assigns.active_invoices)
    hsn_issues = hsn_issues(required_issues)
    novelty = novelty(assigns.account.issues.advisory)
    document_rows = document_summary_rows(assigns.derived)
    human_actions = human_actions(assigns.decisions)
    grouped_cases = grouped_review_cases(assigns.review)
    grouped_targets = grouped_cases |> Enum.flat_map(& &1.targets) |> MapSet.new()

    standalone_issues =
      Enum.reject(required_issues, &MapSet.member?(grouped_targets, SalesWorkings.issue_key(&1)))

    assured_source_ids = assured_source_ids(assigns.review, assigns.invoices, assigns.decisions)

    assigns =
      assigns
      |> assign(:required_issues, required_issues)
      |> assign(:grouped_cases, grouped_cases)
      |> assign(:standalone_issues, standalone_issues)
      |> assign(
        :standalone_blocker_count,
        Enum.count(standalone_issues, &SalesWorkings.blocking?/1)
      )
      |> assign(:assured_invoice_count, MapSet.size(assured_source_ids))
      |> assign(
        :unassured_invoice_count,
        length(assigns.invoices) - MapSet.size(assured_source_ids)
      )
      |> assign(:hsn_summary, hsn_summary)
      |> assign(:hsn_issues, hsn_issues)
      |> assign(:hsn_control, hsn_control(hsn_issues, novelty))
      |> assign(:novelty, novelty)
      |> assign(:novelty_codes, if(novelty, do: novelty.codes, else: []))
      |> assign(:hsn_totals, hsn_totals(hsn_summary))
      |> assign(:document_summary_rows, document_rows)
      |> assign(:document_control, document_control(required_issues, document_rows))
      |> assign(:human_actions, human_actions)
      |> assign(
        :first_review_invoice,
        first_review_invoice(assigns.register_rows, assigns.review)
      )
      |> assign(:section_links, section_links(required_issues, assigns.derived))

    ~H"""
    <section id="month-sales" class="sales-workpaper space-y-section scroll-mt-28">
      <section id="gstr1-overview" class="sales-overview" data-state={@readiness.state}>
        <section
          id="gstr1-verdict"
          class={[
            "sales-verdict",
            Workings.ripple_class(@rippled, @ripple_seq, "gstr1-account")
          ]}
        >
          <div class="sales-verdict-heading">
            <div class="space-y-related min-w-0">
              <p class="text-ink-subtle text-label font-semibold uppercase">Sales return</p>
              <h2 class="text-base-content text-h4 font-semibold">
                {track_title(@sales_month, @r1_signoff)}
              </h2>
            </div>
            <div class="flex flex-wrap items-center gap-2">{render_slot(@primary_action)}</div>
          </div>

          <div class="sales-verdict-figure">
            <p class="text-ink-subtle text-label font-semibold uppercase">
              {output_tax_label(@sales_month, @r1_signoff)}
            </p>
            <p
              id="gstr1-draft-output-tax"
              class="font-display text-base-content text-h3 font-normal tabular-nums"
            >
              {Helpers.rupees(@account.draft.totals.tax)}
            </p>
            <p id="gstr1-draft-position" class="text-body text-ink-muted tabular-nums">
              <span id="gstr1-draft-invoices" class="text-base-content font-medium">
                {document_position_label(@active_invoices, @sales_month, @r1_signoff)}
              </span>
              <span aria-hidden="true"> · </span>
              <span id="gstr1-draft-taxable">
                {Helpers.rupees(@account.draft.totals.taxable)} taxable
              </span>
            </p>
          </div>

          <div class="sales-readiness">
            <span class="sales-readiness-dot" aria-hidden="true"></span>
            <p id="gstr1-filing-status" class="text-base-content text-body font-medium">
              {@readiness.status}
            </p>
          </div>
        </section>

        <section id="gstr1-assurance" class="sales-assurance">
          <div
            :if={is_nil(@r1_signoff) and @account.issues.required_count > 0}
            class="sales-before-approval"
          >
            <p class="text-ink-subtle text-label font-semibold uppercase">Before approval</p>
            <p id="gstr1-required-summary" class="text-base-content text-body font-semibold">
              {review_summary(
                length(@grouped_cases),
                @standalone_blocker_count,
                length(@standalone_issues) - @standalone_blocker_count
              )} before approval
            </p>
          </div>

          <div class="sales-assurance-item">
            <p class="text-ink-subtle text-label font-semibold uppercase">Machine review</p>
            <p class="text-base-content text-ui font-semibold">
              {length(@active_invoices)} processed · {length(@review.needs_you)} {plural(
                length(@review.needs_you),
                "review case"
              )}
            </p>
            <p class="text-ink-muted text-ui">
              Checks find questions; they do not prove every invoice correct.
            </p>
          </div>

          <div class="sales-assurance-item">
            <p class="text-ink-subtle text-label font-semibold uppercase">Human assurance</p>
            <p id="gstr1-human-assurance-count" class="text-base-content text-ui font-semibold">
              {@assured_invoice_count} of {length(@invoices)} invoices have a recorded human action
            </p>
            <p id="gstr1-human-assurance-open" class="text-ink-muted text-ui">
              {@unassured_invoice_count} have no recorded human review. Non-invoice actions do not count toward coverage.
            </p>
          </div>
        </section>
      </section>

      <aside
        :if={@change}
        id="gstr1-what-changed"
        class="sales-change flex items-start justify-between gap-4"
      >
        <div class="space-y-0.5">
          <p class="text-base-content text-ui font-semibold">{@change.title}</p>
          <p class="text-body text-ink-muted">{@change.body}</p>
        </div>
        <button
          type="button"
          phx-click="dismiss-sales-change"
          aria-label="Dismiss change summary"
          class="hover:text-base-content text-ink-faint"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </aside>

      <Workpaper.section_nav links={@section_links} />

      <section
        :if={@grouped_cases != [] or @standalone_issues != []}
        id="gstr1-checks-before-filing"
        class="space-y-block scroll-mt-28"
      >
        <div class="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h3 class="text-base-content text-h4 font-semibold">Required review</h3>
            <p class="text-ink-muted text-ui">
              Only work that can block or change the proposed return.
            </p>
          </div>
          <.button
            :if={@first_review_invoice}
            id="gstr1-review-required"
            patch={sales_review_path(@client, @period, @first_review_invoice, :needs_you)}
            variant="outline"
            size="sm"
          >
            Review required items
          </.button>
        </div>

        <p
          :if={Map.get(@account.issues.by_kind, :blocked, 0) > 0}
          id="gstr1-blocked-next-move"
          class="bg-error/5 border-error/30 rounded-box text-base-content text-body border px-4 py-3"
        >
          Nila files taxable B2B and B2C invoices plus registered credit and debit notes, but another document type in this month is unsupported. File {period_label(
            @period
          )} for {@client.name} manually on the portal and tell us which table you needed.
        </p>

        <div id="gstr1-grouped-review-cases" class="space-y-related">
          <article
            :for={review_case <- @grouped_cases}
            id={"gstr1-review-case-#{review_case.source_id}"}
            class="bg-base-100 border-warning/45 rounded-box flex flex-wrap items-center gap-3 border px-4 py-3"
          >
            <div class="min-w-0 flex-1 space-y-1">
              <p class="text-base-content text-body font-semibold">
                Invoice {review_case.invoice_number}
              </p>
              <p class="text-body text-ink-muted">{review_case.reason}</p>
              <p :if={review_case.effect} class="text-ink-subtle text-ui tabular-nums">
                {review_case.effect}
              </p>
            </div>
            <.button
              variant="outline"
              size="xs"
              patch={
                sales_review_path(
                  @client,
                  @period,
                  review_case.source_id,
                  :needs_you,
                  review_case.target
                )
              }
            >
              Review
            </.button>
          </article>
        </div>

        <div id="gstr1-standalone-required" class="space-y-related">
          <article
            :for={issue <- @standalone_issues}
            id={"gstr1-required-#{:erlang.phash2({SalesWorkings.issue_key(issue), issue["message"]})}"}
            class="bg-base-100 border-warning/45 rounded-box flex flex-wrap items-center gap-3 border px-4 py-3"
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
              href="#gstr1-control-hsn"
              variant="outline"
              size="xs"
              phx-click="review-hsn-issue"
              phx-value-code={Enum.join(hsn_codes(issue), ",")}
            >
              Review HSN rows
            </.button>
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

      <section id="gstr1-return-controls" class="space-y-block scroll-mt-28">
        <div>
          <h3 class="text-base-content text-h4 font-semibold">Return controls</h3>
          <p class="text-ink-muted text-ui">
            Open a schedule when you need its figures or source population.
          </p>
        </div>

        <div class="bg-base-100 border-base-300 divide-base-300 rounded-box divide-y border">
          <.fold
            :if={@derived}
            id="gstr1-filing-summary"
            open={MapSet.member?(@open_folds, "gstr1-filing-summary")}
            class="px-4"
            summary_class="py-4 text-base-content w-full"
          >
            <:summary>
              <.fold_summary title="Proposed GSTR-1 derived from effective sales register" tabular>
                <:detail>
                  {length(@active_invoices)} documents · {Helpers.rupees(
                    @account.draft.totals.taxable
                  )} taxable · {Helpers.rupees(@account.draft.totals.tax)} tax
                  <span :if={@required_issues != []}> · blockers disclosed above</span>
                </:detail>
                <:status>
                  <.badge variant="neutral">Derived</.badge>
                </:status>
              </.fold_summary>
            </:summary>
            <div class="space-y-related pb-4">
              <h4 class="text-base-content text-body font-semibold">{@readiness.title}</h4>
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
            </div>
          </.fold>

          <.fold
            :if={@hsn_summary != []}
            id="gstr1-control-hsn"
            open={MapSet.member?(@open_folds, "gstr1-control-hsn")}
            class="px-4"
            summary_class="py-4 text-base-content w-full"
          >
            <:summary>
              <.fold_summary title="HSN Table 12 derived from effective invoice lines" tabular>
                <:detail>
                  {length(@hsn_summary)} combinations · {Helpers.rupees(@hsn_totals.tax)} tax
                  <span :if={@novelty}> · {@novelty.count} codes new</span>
                </:detail>
                <:status>
                  <.badge variant={@hsn_control.variant}>{@hsn_control.label}</.badge>
                </:status>
              </.fold_summary>
            </:summary>
            <section id="gstr1-hsn-signoff" class="space-y-block pb-4">
              <div class="flex flex-wrap items-center justify-between gap-3">
                <h4 class="text-base-content text-body font-semibold">HSN summary · Table 12</h4>
                <.link
                  :if={@hsn_issues != []}
                  href="#gstr1-checks-before-filing"
                  class="text-ui text-warning font-medium underline"
                >
                  {length(@hsn_issues)} HSN {plural(length(@hsn_issues), "check")} in required work
                </.link>
              </div>
              <p :if={@novelty} id="gstr1-hsn-new-codes" class="text-ink-muted text-ui font-medium">
                {@novelty.count} of {length(@hsn_summary)} codes are new for this client
              </p>
              <Workings.hsn_summary
                derived={@derived}
                invoices={@active_invoices}
                novelty_codes={@novelty_codes}
                rippled={@rippled}
                ripple_seq={@ripple_seq}
                expanded={@expanded_nodes}
              />
            </section>
          </.fold>

          <.fold
            :if={@document_summary_rows != []}
            id="gstr1-control-documents"
            open={MapSet.member?(@open_folds, "gstr1-control-documents")}
            class="px-4"
            summary_class="py-4 text-base-content w-full"
          >
            <:summary>
              <.fold_summary title="Extracted document sequence">
                <:detail>{@document_control.copy}</:detail>
                <:status>
                  <.badge variant={@document_control.variant}>{@document_control.label}</.badge>
                </:status>
              </.fold_summary>
            </:summary>
            <section id="gstr1-document-summary" class="space-y-related pb-4">
              <h4 class="text-base-content text-body font-semibold">Documents issued · Table 13</h4>
              <p class="text-ink-muted text-ui">
                This checks only the extracted numbers for an internal gap. It is not an independent issued-document register and does not prove completeness.
              </p>
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
          </.fold>
        </div>
      </section>

      <section id="gstr1-register" class="space-y-block scroll-mt-28">
        <div class="flex flex-wrap items-end justify-between gap-4">
          <div>
            <h3 class="text-base-content text-h4 font-semibold">Sales register</h3>
            <p class="text-ink-muted text-ui">
              {length(@register_rows)} of {length(@invoices)} documents shown
            </p>
          </div>
          <.button
            :if={@first_review_invoice}
            id="gstr1-register-review-next"
            patch={sales_review_path(@client, @period, @first_review_invoice, :needs_you)}
            variant="outline"
            size="xs"
          >
            Review next
          </.button>
        </div>

        <div class="flex flex-col gap-3 lg:flex-row lg:items-end lg:justify-between">
          <.form
            for={@register_form}
            id="gstr1-register-search"
            phx-change="search-sales-register"
            class="w-full max-w-sm"
          >
            <.input
              field={@register_form[:query]}
              type="search"
              label="Search sales register"
              placeholder="Invoice, buyer or GSTIN"
            />
          </.form>
          <.segmented_control
            id="gstr1-register-filters"
            items={[
              {:review_cases, "Review cases"},
              {:no_open_checks, "No open checks"},
              {:all, "All"}
            ]}
            selected={@register_filter}
            on_change="filter-sales-register"
            value_name="filter"
          />
        </div>

        <.invoice_table
          id="gstr1-invoices"
          rows={@register_rows}
          visited={@visited}
          reviewed_invoice={@reviewed_invoice}
          issues_by_invoice={@issues_by_invoice}
          decisions={@decisions}
          client={@client}
          period={@period}
        />
        <p id="gstr1-register-basis" class="text-ink-subtle text-ui">
          These are the lines as extracted. The return files a per-rate recomputation, shown under Return workings.
        </p>
      </section>

      <section :if={@derived} id="gstr1-return" class="space-y-block scroll-mt-28">
        <h3 class="text-base-content text-h4 font-semibold">Return workings</h3>
        <Workings.workings_body
          derived={@derived}
          invoices={@active_invoices}
          diff={@diff}
          accepted={@accepted_diffs}
          locked={not is_nil(@r1_signoff)}
          rippled={@rippled}
          ripple_seq={@ripple_seq}
          expanded={@expanded_nodes}
          open_folds={@open_folds}
        />
      </section>

      <section id="gstr1-source-documents" class="space-y-block scroll-mt-28">
        <div>
          <h3 class="text-base-content text-h4 font-semibold">Evidence and history</h3>
          <p class="text-ink-muted text-ui">
            Source packets and attributed actions behind the effective register.
          </p>
        </div>
        {render_slot(@source)}
        <div
          :if={@human_actions != []}
          id="gstr1-action-history"
          class="border-base-300 divide-base-300 rounded-box divide-y border"
        >
          <div
            :for={action <- @human_actions}
            class="flex flex-wrap items-center justify-between gap-3 px-4 py-3"
          >
            <div>
              <p class="text-base-content text-ui font-medium">{action_label(action)}</p>
              <p class="text-ink-muted text-ui">{action.target}</p>
            </div>
            <.context_text tag="p">
              {(action.decided_by && action.decided_by.name) || "Unknown reviewer"} · {format_display_datetime(
                action.inserted_at
              )}
            </.context_text>
          </div>
        </div>
        <p
          :if={@r1_signoff && @r1_signoff.snapshot["draft_version"]}
          id="gstr1-approved-version"
          class="text-ink-muted text-ui"
        >
          Approved version
          <span class="text-base-content font-mono">{String.slice(
            @r1_signoff.snapshot["draft_version"],
            0,
            12
          )}</span>
        </p>
      </section>

      {render_slot(@actions)}
    </section>
    """
  end

  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :visited, :any, default: MapSet.new()
  attr :reviewed_invoice, :string, default: nil
  attr :issues_by_invoice, :map, required: true
  attr :decisions, :map, default: %{}
  attr :client, :map, required: true
  attr :period, :string, required: true

  defp invoice_table(assigns) do
    assigns =
      assign(assigns, :number_counts, Enum.frequencies_by(assigns.rows, & &1["invoice_number"]))

    ~H"""
    <.data_table
      id={@id}
      rows={@rows}
      row_id={fn invoice -> invoice_dom_id(invoice, @number_counts) end}
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
          (invoice["id"] == @reviewed_invoice or invoice["invoice_number"] == @reviewed_invoice or
             invoice["pristine_inum"] == @reviewed_invoice) &&
            "nila-sales-register-row-reviewed"
        end
      }
      min_width="min-w-[920px]"
    >
      <:col :let={invoice} label="Document No">
        <span class={[
          "font-mono",
          if(MapSet.member?(@visited, invoice["id"] || invoice["invoice_number"]),
            do: "text-ink-muted",
            else: "text-base-content font-medium"
          )
        ]}>
          {invoice["invoice_number"] || "—"}
        </span>
      </:col>
      <:col :let={invoice} label="Date">{format_display_date(invoice["invoice_date"])}</:col>
      <:col :let={invoice} label="Buyer">
        <span class="block max-w-64 truncate" title={invoice["buyer_name"]}>{invoice["buyer_name"] ||
          "—"}</span>
      </:col>
      <:col :let={invoice} label="Recipient">
        <span class="text-ink-muted font-mono">{invoice["buyer_gstin"] || registration_label(invoice)}</span>
      </:col>
      <:col :let={invoice} label="POS">
        <span class="text-ink-muted font-mono">{invoice["place_of_supply"] || "—"}</span>
      </:col>
      <:col :let={invoice} label="Taxable" align="right">
        {Helpers.rupees(Gstr1.extracted_totals(invoice).taxable)}
      </:col>
      <:col :let={invoice} label="Extracted GST" align="right">
        {Helpers.rupees(Gstr1.extracted_totals(invoice).tax)}
      </:col>
      <:col :let={invoice} label="Machine state">
        <.badge variant={machine_state(@issues_by_invoice, invoice).variant}>
          {machine_state(@issues_by_invoice, invoice).label}
        </.badge>
      </:col>
      <:col :let={invoice} label="Human action">
        <span class="text-ink-muted text-ui">{human_state(@issues_by_invoice, @decisions, invoice)}</span>
      </:col>
      <:col label="" align="right">
        <.icon name="hero-chevron-right-mini" class="text-ink-faint size-4" />
      </:col>
      <:empty>No sales documents match these filters.</:empty>
    </.data_table>
    """
  end

  defp section_links(required_issues, derived) do
    [
      required_issues != [] && %{id: "gstr1-checks-before-filing", label: "Required review"},
      derived && %{id: "gstr1-return-controls", label: "Return controls"},
      %{id: "gstr1-register", label: "Register"},
      derived && %{id: "gstr1-return", label: "Workings"},
      %{id: "gstr1-source-documents", label: "Evidence"},
      %{id: "gstr1-handoff", label: "Approval & handoff"}
    ]
    |> Enum.filter(&is_map/1)
  end

  defp first_review_invoice(rows, %{needs_you: needs_you}) do
    visible = MapSet.new(rows, & &1["id"])

    case Enum.find(needs_you, &MapSet.member?(visible, &1.source_id)) do
      nil -> nil
      item -> item.source_id
    end
  end

  defp machine_state(_issues_by_invoice, %{"duplicate_copy" => _copy}),
    do: %{variant: "neutral", label: "Duplicate copy"}

  defp machine_state(issues_by_invoice, invoice) do
    issues = Helpers.invoice_issues(issues_by_invoice, invoice)

    open =
      Enum.any?(
        issues,
        &(&1["status"] == "open" and
            Issues.resolution_kind(&1) in [:decision, :correction, :confirmation])
      )

    if open,
      do: %{variant: "warning", label: "Review case"},
      else: %{variant: "neutral", label: "No open checks"}
  end

  defp human_state(issues_by_invoice, decisions, invoice) do
    targets = [
      invoice["id"]
      | Enum.map(Helpers.invoice_issues(issues_by_invoice, invoice), &SalesWorkings.issue_key/1)
    ]

    action = Enum.find_value(targets, &decisions[&1])

    case action && action.verb do
      "correct_field" -> "Corrected"
      "confirm_issue" -> "Confirmed"
      "exclude_duplicate_copy" -> "Excluded as duplicate"
      _ -> "No recorded action"
    end
  end

  defp human_actions(decisions) do
    decisions
    |> Map.values()
    |> Enum.reject(&(&1.verb == "reopen"))
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
  end

  defp grouped_review_cases(review) do
    Enum.flat_map(review.needs_you, fn item ->
      issues =
        Enum.filter(item.actionable_issues, fn issue ->
          issue["status"] == "open" and groupable_invoice_issue?(issue)
        end)

      case issues do
        [] ->
          []

        [first | _] ->
          [
            %{
              source_id: item.source_id,
              invoice_number: item.invoice["invoice_number"] || "—",
              target: SalesWorkings.issue_key(first),
              targets: Enum.map(issues, &SalesWorkings.issue_key/1),
              reason: grouped_reason(issues),
              effect: treatment_effect(item.treatment)
            }
          ]
      end
    end)
  end

  defp groupable_invoice_issue?(issue),
    do: not is_binary(issue["hsn_code"]) and issue["code"] != "duplicate_invoice_number"

  defp grouped_reason([issue]), do: issue["message"]

  defp grouped_reason([first | rest]) do
    "#{issue_label(first["code"])}: #{first["message"]} · #{length(rest)} related #{plural(length(rest), "check")} grouped with this invoice"
  end

  defp treatment_effect(nil), do: nil

  defp treatment_effect(treatment) do
    "Current draft: #{String.upcase(treatment["table"] || "return")} · #{Helpers.rupees(treatment["taxable_amount"])} taxable · #{Helpers.rupees(treatment["tax_amount"])} tax"
  end

  defp assured_source_ids(review, invoices, decisions) do
    invoice_ids = MapSet.new(invoices, & &1["id"])

    decisions
    |> Map.values()
    |> Enum.reject(&(&1.verb == "reopen"))
    |> Enum.reduce(MapSet.new(), fn action, covered ->
      case assured_source_id(action, review, invoice_ids) do
        nil -> covered
        source_id -> MapSet.put(covered, source_id)
      end
    end)
  end

  defp assured_source_id(%{verb: "correct_field", target: target}, _review, invoice_ids),
    do: if(MapSet.member?(invoice_ids, target), do: target)

  defp assured_source_id(
         %{verb: "exclude_duplicate_copy", payload: payload},
         _review,
         invoice_ids
       ) do
    source_id = payload["excluded_source_id"]
    if MapSet.member?(invoice_ids, source_id), do: source_id
  end

  defp assured_source_id(%{verb: "confirm_issue", target: target}, review, _invoice_ids) do
    case Enum.find(review.all, &(target in &1.actionable_targets)) do
      nil -> nil
      item -> item.source_id
    end
  end

  defp assured_source_id(_action, _review, _invoice_ids), do: nil

  defp review_summary(review_cases, blockers, required_checks) do
    [
      review_cases > 0 && "#{review_cases} #{plural(review_cases, "review case")}",
      blockers > 0 && "#{blockers} #{plural(blockers, "blocker")}",
      required_checks > 0 &&
        "#{required_checks} #{plural(required_checks, "required check")}"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" · ")
  end

  defp action_label(%{verb: "correct_field", payload: %{"field" => field}}),
    do: "Corrected #{humanize_label(field)}"

  defp action_label(%{verb: "confirm_issue"}), do: "Confirmed Nila's proposed treatment"
  defp action_label(%{verb: "accept_difference"}), do: "Accepted filed-return difference"
  defp action_label(%{verb: "exclude_duplicate_copy"}), do: "Excluded duplicate source copy"
  defp action_label(action), do: humanize_label(action.verb)

  defp hsn_control([issue | _], _novelty),
    do: %{label: issue_level_label(issue), variant: Helpers.severity_variant(issue["level"])}

  defp hsn_control([], %{}), do: %{label: "Advisory", variant: "neutral"}
  defp hsn_control([], nil), do: %{label: "Derived", variant: "neutral"}

  defp issue_level_label(%{"level" => "blocking"}), do: "Blocked"
  defp issue_level_label(_issue), do: "Review required"

  defp document_control(required_issues, rows) do
    sequence? =
      Enum.any?(
        required_issues,
        &(&1["code"] in ~w(invoice_sequence_gap duplicate_invoice_number))
      )

    first = List.first(rows)
    copy = if first, do: "#{first.from} to #{first.to}", else: "No extracted series"

    if sequence? do
      %{label: "Review required", variant: "warning", copy: copy}
    else
      %{
        label: "Not independently tested",
        variant: "neutral",
        copy: copy <> " · no internal gap observed"
      }
    end
  end

  defp invoice_dom_id(invoice, number_counts) do
    identity =
      if number_counts[invoice["invoice_number"]] == 1,
        do: invoice["invoice_number"],
        else: invoice["id"]

    "gstr1-inv-#{identity}"
  end

  defp track_title(%{filed_at: filed_at}, %{}) when not is_nil(filed_at), do: "GSTR-1 filed"
  defp track_title(_sales_month, %{}), do: "GSTR-1 approved"
  defp track_title(_sales_month, _signoff), do: "GSTR-1 draft"

  defp output_tax_label(_sales_month, %{}), do: "Approved output tax"
  defp output_tax_label(_sales_month, _signoff), do: "Proposed output tax"

  defp document_position_label(invoices, _sales_month, %{}),
    do: document_mix_label(invoices) <> " in approved return"

  defp document_position_label(invoices, _sales_month, _signoff),
    do: document_mix_label(invoices) <> " in draft"

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
    isolated =
      Enum.reduce(~w(b2b b2cs b2cl cdnr), derived, fn key, acc ->
        if key == section, do: acc, else: Map.put(acc, key, [])
      end)

    Values.filed_totals(isolated)
  end

  defp filing_summary_row(key, label, documents, totals),
    do: %{
      key: key,
      label: label,
      documents: documents,
      taxable: totals.taxable,
      igst: totals.igst,
      cgst: totals.cgst,
      sgst: totals.sgst
    }

  defp count_documents(derived, section, rows),
    do: derived |> Map.get(section, []) |> Enum.reduce(0, &(length(&1[rows] || []) + &2))

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

  defp hsn_issues(issues), do: Enum.filter(issues, &is_binary(&1["hsn_code"]))

  defp novelty(advisories) do
    case Enum.filter(advisories, &(&1["code"] == "hsn_new_code")) do
      [] ->
        nil

      issues ->
        codes = issues |> Enum.map(& &1["hsn_code"]) |> Enum.uniq() |> Enum.sort()
        %{count: length(codes), codes: codes}
    end
  end

  defp hsn_reviewed?(issue, invoices, expanded_nodes) do
    case Enum.flat_map(hsn_codes(issue), &Workings.hsn_node_ids(invoices, &1)) do
      [] -> false
      nodes -> Enum.all?(nodes, &MapSet.member?(expanded_nodes, &1))
    end
  end

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
      |> Enum.any?(
        &(&1["status"] == "open" and
            Issues.resolution_kind(&1) in [:decision, :correction, :confirmation])
      )

    if actionable?, do: :needs_you, else: :all
  end

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"
end
