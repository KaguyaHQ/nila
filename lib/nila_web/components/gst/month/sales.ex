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
      |> assign(:reconciliation_rows, reconciliation_rows(assigns.account))

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
              :if={issue["code"] == "duplicate_invoice_number"}
              variant="outline"
              size="xs"
              phx-click="open-duplicate-review"
              phx-value-target={SalesWorkings.issue_key(issue)}
            >
              Review copies
            </.button>
            <.button
              :if={is_binary(issue["source_id"])}
              variant="outline"
              size="xs"
              phx-click="review-sales-issue"
              phx-value-source={issue["source_id"]}
              phx-value-target={SalesWorkings.issue_key(issue)}
            >
              Review
            </.button>
            <.button
              :if={is_nil(issue["source_id"]) and issue["level"] != "blocking"}
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
          <.badge variant={completeness_variant(@completeness)}>
            {completeness_label(@completeness)}
          </.badge>
        </div>

        <div class="border-base-300 rounded-box grid gap-4 border p-4 sm:grid-cols-2 lg:grid-cols-4">
          <.control_stat label="Source files received" value={@account.source.files} />
          <.control_stat
            label="Invoice pages read"
            value={@account.source.pages_read || "Not recorded"}
          />
          <.control_stat label="Invoices extracted" value={@account.extraction.documents} />
          <.control_stat
            label="Unique invoice numbers"
            value={@account.extraction.unique_invoice_numbers}
          />
          <.control_stat label="Active draft documents" value={@account.draft.documents} />
          <.control_stat
            label="Sequence gaps"
            value={if(@series, do: length(@series.missing), else: "Not checked")}
          />
          <.control_stat
            label="Duplicate copies excluded"
            value={@account.extraction.duplicate_copies}
          />
          <.control_stat label="Cess" value="Not captured" />
        </div>

        <.data_table id="gstr1-reconciliation" rows={@reconciliation_rows} dense>
          <:col :let={row} label="Control">{row.label}</:col>
          <:col :let={row} label="Source register" align="right">{row.extracted}</:col>
          <:col :let={row} label="GSTR-1 draft" align="right">{row.draft}</:col>
          <:col :let={row} label="Difference" align="right">
            <span class={row.changed && "text-warning font-medium"}>{row.difference}</span>
          </:col>
        </.data_table>

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
       do: %{variant: "neutral", label: "Filed", copy: "The signed return is on the GST portal."}

  defp verdict_state(%{r1_signoff: %{}}),
    do: %{variant: "info", label: "Signed", copy: "Signed and waiting to be filed on the portal."}

  defp verdict_state(%{account: %{issues: %{required_count: count}}}) when count > 0,
    do: %{
      variant: "error",
      label: "Blocked",
      copy: "#{count} #{plural(count, "check")} must be resolved before approval."
    }

  defp verdict_state(%{completeness: completeness}) when completeness != :complete,
    do: %{
      variant: "warning",
      label: "Collection open",
      copy: "Invoice work may continue, but filing waits for current client completeness."
    }

  defp verdict_state(%{sales_month: %{state: "reviewed"}}),
    do: %{
      variant: "success",
      label: "Ready to sign",
      copy: "Review is complete and collection is confirmed."
    }

  defp verdict_state(_assigns),
    do: %{
      variant: "info",
      label: "Ready for review",
      copy: "No filing blockers remain in the draft."
    }

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
        account.extraction.active_documents,
        account.draft.documents,
        account.draft.documents - account.extraction.active_documents,
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
      account.extraction.totals[key],
      account.draft.totals[key],
      account.differences[key],
      :money
    )
  end

  defp reconciliation_row(label, extracted, draft, difference, :count) do
    %{
      label: label,
      extracted: extracted,
      draft: draft,
      difference: difference,
      changed: difference != 0
    }
  end

  defp reconciliation_row(label, extracted, draft, difference, :money) do
    %{
      label: label,
      extracted: Helpers.rupees(extracted),
      draft: Helpers.rupees(draft),
      difference: Helpers.rupees(difference),
      changed: abs(difference) >= 0.01
    }
  end

  defp issues_clause(0), do: "Ready"
  defp issues_clause(1), do: "1 check"
  defp issues_clause(n), do: "#{n} checks"

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"

  defp rupees(amount), do: Helpers.rupees(amount)
end
