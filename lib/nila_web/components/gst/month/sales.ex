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
      |> assign(:required_issues, assigns.account.issues.required)
      |> assign(:verdict, verdict_state(assigns))
      |> assign(:draft_label, draft_label(assigns))
      |> assign(:reconciliation_rows, reconciliation_rows(assigns.account))
      |> assign(:hsn_summary, Gstr1.hsn_summary(assigns.active_invoices))
      |> assign(:hsn_issues, hsn_issues(assigns.account.issues.required))
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
          <.button
            :if={@open_issue_count > 0}
            id="gstr1-review-required"
            href="#gstr1-checks-before-filing"
            variant="primary"
            size="sm"
          >
            Review {@open_issue_count} {plural(@open_issue_count, "check")}
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

      <section
        :if={@required_issues != []}
        id="gstr1-checks-before-filing"
        class="space-y-block scroll-mt-28"
      >
        <div class="flex items-center justify-between gap-3">
          <h3 class="text-base-content text-body font-semibold">Checks before filing</h3>
          <span class="text-error text-small font-medium">
            {length(@required_issues)} unresolved
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
              <p :if={issue["invoice"]} class="text-base-content text-small font-medium">
                Invoice {issue["invoice"]}
              </p>
              <p class="text-body text-ink-muted">{issue["message"]}</p>
            </div>
            <.button
              :if={is_binary(issue["hsn_code"])}
              href="#gstr1-workings-hsn"
              variant="outline"
              size="xs"
              phx-click="review-hsn-issue"
              phx-value-code={issue["hsn_code"]}
            >
              Review HSN rows
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
              phx-click="review-sales-issue"
              phx-value-source={issue["source_id"]}
              phx-value-target={SalesWorkings.issue_key(issue)}
            >
              Review
            </.button>
            <.button
              :if={
                !is_binary(issue["hsn_code"]) and is_nil(issue["source_id"]) and
                  issue["level"] != "blocking"
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
              <span class="text-ink-muted text-small">
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
          <div :if={@hsn_issues != []} class="space-y-related">
            <div
              :for={issue <- @hsn_issues}
              id={"gstr1-hsn-issue-#{:erlang.phash2(SalesWorkings.issue_key(issue))}"}
              class="border-base-300 flex flex-wrap items-center gap-3 border-t pt-3"
            >
              <p class="text-base-content text-small min-w-0 flex-1">{issue["message"]}</p>
              <.button
                :if={!hsn_reviewed?(issue, @active_invoices, @expanded_nodes)}
                href="#gstr1-workings-hsn"
                variant="outline"
                size="xs"
                phx-click="review-hsn-issue"
                phx-value-code={issue["hsn_code"]}
              >
                Review
              </.button>
              <.button
                :if={
                  hsn_reviewed?(issue, @active_invoices, @expanded_nodes) and
                    is_nil(issue["source_id"]) and issue["level"] != "blocking"
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
            </div>
          </div>
        </section>

        <p class="text-ink-muted text-small">{confirmation_note(@confirmation, @completeness)}</p>
      </section>

      <section class="space-y-block">
        <h3 class="text-base-content text-body font-semibold">Source documents</h3>
        {render_slot(@source)}
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
      <:col :let={invoice} label="Tax" align="right">
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
    open = Enum.count(issues, &(&1["status"] == "open" and &1["level"] != "info"))

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

  defp verdict_state(%{account: %{issues: %{required_count: count}}}) when count > 0,
    do: %{
      variant: "error",
      label: "Blocked",
      copy: "#{count} #{plural(count, "check")} must be resolved before approval."
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
        issue["code"] in ~w(hsn_multiple_rates hsn_new_code hsn_inferred_code rate_history_conflict statutory_rate_mismatch statutory_rate_review invalid_hsn_sac incomplete_hsn_sac)
    end)
  end

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
  defp cess_label(:not_evaluated), do: "Not evaluated · filing blocked"

  defp issues_clause(0), do: "Ready"
  defp issues_clause(1), do: "1 check"
  defp issues_clause(n), do: "#{n} checks"

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"

  defp rupees(amount), do: Helpers.rupees(amount)
end
