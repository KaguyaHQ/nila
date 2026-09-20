defmodule NilaWeb.Components.Gst.Month.Filing do
  use NilaWeb, :html

  @moduledoc "Audited return actions rendered directly after their evidence."

  alias Nila.Gst.Filing.{Gstr3b, ItcPosition, WinmanGstr1}
  alias Nila.Gst.Sales.Review.Values
  alias NilaWeb.Components.Gst.Month.Helpers

  attr :sales_month, :any, required: true
  attr :open_issue_count, :integer, required: true
  attr :reviewable, :boolean, required: true
  attr :sales_intake_open, :boolean, default: false
  attr :can_sign_off, :boolean, required: true
  attr :derived, :any, default: nil
  attr :readiness, :map, required: true
  attr :review_case_count, :integer, default: 0

  def gstr1_primary_action(assigns) do
    ~H"""
    <.button
      :if={@readiness.state == :provisional and @review_case_count > 0}
      id="gstr1-primary-review"
      patch={~p"/gst/#{@sales_month.client_id}/#{@sales_month.period}/review/sales?scope=needs_you"}
      variant="soft"
      size="sm"
    >
      Review next item
    </.button>

    <.button
      :if={@readiness.state == :ready}
      id="gstr1-primary-handoff"
      href={~p"/gstr1/#{@sales_month.client_id}/#{@sales_month.period}/workings.xlsx"}
      download
      variant="primary"
      size="sm"
    >
      Download working Excel
    </.button>

    <.badge :if={@readiness.state == :filed} variant="neutral">Filed</.badge>
    """
  end

  attr :sales_month, :any, required: true
  attr :open_issue_count, :integer, required: true
  attr :reviewable, :boolean, required: true
  attr :sales_intake_open, :boolean, default: false
  attr :can_sign_off, :boolean, required: true
  attr :derived, :any, default: nil
  attr :readiness, :map, required: true
  attr :handoff, :map, default: nil
  attr :tally_companies, :list, default: []

  def gstr1_actions(assigns) do
    assigns = assign(assigns, :filed, assigns.derived && Values.filed_totals(assigns.derived))

    ~H"""
    <div id="gstr1-handoff" class="py-section space-y-related">
      <section id="month-exit-gstr1" class="border-rule pt-block scroll-mt-28 border-t">
        <div class="space-y-1">
          <h3 class="text-base-content text-h4 font-semibold">Working files</h3>

          <p id="gstr1-working-status" class="text-base-content text-body font-medium">
            {@readiness.action_copy || @readiness.status}
          </p>
        </div>

        <.button
          :if={@readiness.state in [:ready, :filed]}
          id="gstr1-guide-download-json"
          href={~p"/gstr1/#{@sales_month.client_id}/#{@sales_month.period}/return.json"}
          download
          variant="outline"
          size="xs"
        >
          Download GST JSON
        </.button>
      </section>

      <section
        :if={@readiness.state in [:ready, :filed] and @handoff}
        id="gstr1-winman-b2b-export"
        class="nila-gstr1-handoff rounded-box space-y-block border p-6"
      >
        <div class="gap-block flex flex-wrap items-start justify-between">
          <div class="space-y-1">
            <p class="text-ink-subtle text-label font-semibold uppercase">Primary handoff</p>

            <p class="text-base-content text-h4 font-semibold">Winman B2B sheet</p>

            <p class="text-body text-ink-subtle">
              Only the B2B sheet is populated in this version.
            </p>
          </div>

          <.button
            :if={WinmanGstr1.supported_period?(@sales_month.period)}
            id="gstr1-download-winman-b2b"
            href={~p"/gstr1/#{@sales_month.client_id}/#{@sales_month.period}/winman-b2b.xlsm"}
            download
            variant="primary"
            size="sm"
          >
            Download Winman B2B
          </.button>

          <.badge :if={not WinmanGstr1.supported_period?(@sales_month.period)} variant="warning">
            Period not supported by this workbook
          </.badge>
        </div>

        <dl id="gstr1-handoff-manifest" class="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
          <div>
            <dt class="text-ink-subtle text-label font-semibold uppercase">Included in workbook</dt>

            <dd class="text-base-content text-ui font-semibold">
              {@handoff.included_documents} B2B workbook {plural(@handoff.included_documents, "row")}
            </dd>

            <p class="text-ink-muted text-ui">
              From {@handoff.included_b2b_invoices} B2B {plural(
                @handoff.included_b2b_invoices,
                "invoice"
              )}
            </p>
          </div>

          <div>
            <dt class="text-ink-subtle text-label font-semibold uppercase">Recorded review</dt>

            <dd class="text-base-content text-ui font-semibold">
              {@handoff.confirmations} {plural(@handoff.confirmations, "confirmation")} · {@handoff.corrections} {plural(
                @handoff.corrections,
                "correction"
              )}
            </dd>

            <p :if={@handoff.omitted_documents > 0} class="text-ink-muted text-ui">
              {@handoff.omitted_documents} supported {plural(
                @handoff.omitted_documents,
                "document"
              )} omitted from this B2B workbook version · {Enum.map_join(
                @handoff.omitted_by_table,
                " · ",
                &"#{&1.label} #{&1.count}"
              )}
            </p>
          </div>

          <div>
            <dt class="text-ink-subtle text-label font-semibold uppercase">Held out</dt>

            <dd class="text-base-content text-ui font-semibold">
              {@handoff.duplicates_excluded} duplicate {plural(
                @handoff.duplicates_excluded,
                "copy",
                "copies"
              )} · {@handoff.review_cases_held} review {plural(@handoff.review_cases_held, "case")} · {@handoff.blockers_held} {plural(
                @handoff.blockers_held,
                "blocker"
              )}
            </dd>

            <p :if={@handoff.unsupported_held > 0} class="text-ink-muted text-ui">
              {@handoff.unsupported_held} unsupported {plural(@handoff.unsupported_held, "record")} held
            </p>
          </div>

          <div>
            <dt class="text-ink-subtle text-label font-semibold uppercase">
              Winman B2B control totals
            </dt>

            <dd class="text-base-content text-ui font-semibold tabular-nums">
              {Helpers.rupees(@handoff.taxable)} taxable · {Helpers.rupees(@handoff.output_tax)} tax
            </dd>
          </div>
        </dl>
      </section>

      <section
        :if={@readiness.state in [:ready, :filed]}
        id="gstr1-tally-export"
        class="gap-block flex flex-wrap items-center justify-between"
      >
        <div class="space-y-1">
          <p class="text-ink-subtle text-label font-semibold uppercase">Accounting handoff</p>

          <p class="text-base-content text-ui font-medium">TallyPrime · GL sales vouchers</p>

          <p class="text-body text-ink-subtle">
            Download the GL sales vouchers, or open sales bills to send them through Nila Connector.
            GST return metadata is not included.
          </p>
        </div>

        <div class="flex flex-wrap gap-2">
          <.button
            id="gstr1-download-tally"
            href={~p"/gstr1/#{@sales_month.client_id}/#{@sales_month.period}/tally.xml"}
            download
            variant="outline"
            size="xs"
          >
            <.icon name="hero-arrow-down-tray" class="size-4" /> Download Tally XML
          </.button>

          <.button
            id="gstr1-open-sales-bills"
            navigate={~p"/gst/#{@sales_month.client_id}/#{@sales_month.period}/sales"}
            variant="outline"
            size="xs"
          >
            Open sales bills
          </.button>
        </div>
      </section>
    </div>
    """
  end

  @doc "The one lifecycle and gate result used by the GSTR-1 preview and its action."
  def gstr1_readiness(%{sales_month: nil}),
    do: %{state: :absent, title: "Proposed GSTR-1", status: nil, action_copy: nil}

  def gstr1_readiness(assigns) do
    cond do
      not is_nil(assigns.sales_month.filed_at) ->
        %{
          state: :filed,
          title: "Filed GSTR-1",
          status: "Filed on the GST portal",
          action_copy: nil
        }

      not assigns.reviewable or assigns.sales_intake_open ->
        provisional_readiness(assigns)

      true ->
        %{
          state: :ready,
          title: "GSTR-1 working",
          status: "Working files ready",
          action_copy: "Download the working files for review"
        }
    end
  end

  defp provisional_readiness(assigns) do
    required = assigns.open_issue_count
    intake? = assigns.sales_intake_open

    {status, action_copy} =
      cond do
        required > 0 and intake? ->
          {"Provisional — required work and a sales packet remain unresolved",
           "Blocked · #{required} required #{if required == 1, do: "item", else: "items"} and a sales packet remain unresolved"}

        required > 0 ->
          item = if required == 1, do: "item", else: "items"

          {"Provisional — #{required} required #{item} #{if required == 1, do: "remains", else: "remain"}",
           "Blocked · #{required} required #{item} #{if required == 1, do: "remains", else: "remain"}"}

        intake? ->
          {"Provisional — a sales packet remains unresolved",
           "Blocked · 1 sales packet remains unresolved"}

        true ->
          {"Provisional — sales checks are incomplete", "Blocked · sales checks are incomplete"}
      end

    %{
      state: :provisional,
      title: "Proposed GSTR-1",
      status: status,
      action_copy: action_copy
    }
  end

  attr :purchase_month, :any, required: true
  attr :sales_month, :any, default: nil
  attr :sales_reviewable, :boolean, default: false
  attr :stats, :any, required: true
  attr :gstr3b_signoff, :any, default: nil
  attr :can_sign_off, :boolean, required: true
  attr :sales_intake_open, :boolean, default: false
  attr :itc, :any, default: nil
  attr :gstr3b, :any, default: nil

  def gstr3b_primary_action(assigns) do
    blockers = gstr3b_blockers(assigns)
    first_blocker = List.first(blockers)
    assigns = assign(assigns, blockers: blockers, first_blocker: first_blocker)

    ~H"""
    <div id="gstr3b-primary-action" class="flex flex-wrap items-center gap-2">
      <.button
        :if={is_nil(@gstr3b_signoff) and @blockers == [] and @can_sign_off}
        id="month-door-sign-3b"
        variant="primary"
        size="sm"
        phx-click="3b-sign-off"
      >
        Sign the GSTR-3B
      </.button>

      <.blocker_exit
        :if={is_nil(@gstr3b_signoff) and @first_blocker}
        blocker={@first_blocker}
        id="gstr3b-primary-blocker"
        variant="primary"
      />
      <.button
        :if={not is_nil(@gstr3b_signoff) and is_nil(@purchase_month.filed_at)}
        id="gstr3b-primary-filing"
        href="#month-exit-gstr3b"
        variant="primary"
        size="sm"
      >
        Record portal filing
      </.button>
    </div>
    """
  end

  attr :purchase_month, :any, required: true
  attr :sales_month, :any, default: nil
  attr :sales_reviewable, :boolean, default: false
  attr :stats, :any, required: true
  attr :gstr3b_signoff, :any, default: nil
  attr :can_sign_off, :boolean, required: true
  attr :sales_intake_open, :boolean, default: false
  attr :itc, :any, default: nil
  attr :gstr3b, :any, default: nil

  def gstr3b_blocker_list(assigns) do
    blockers = gstr3b_blockers(assigns)
    assigns = assign(assigns, blockers: blockers, primary_blocker: List.first(blockers))

    ~H"""
    <section :if={@blockers != []} id="gstr3b-blockers" class="space-y-block scroll-mt-28">
      <div>
        <h3 class="text-base-content text-h4 font-semibold">What blocks this return</h3>

        <p class="text-ink-muted text-ui">Each requirement links to the work that clears it.</p>
      </div>

      <ul
        id="month-exit-gstr3b-blocked"
        class="bg-panel-surface border-rule divide-rule rounded-box divide-y border"
      >
        <li
          :for={{key, message, exit} <- @blockers}
          id={"gstr3b-blocker-#{key}"}
          class="gap-block flex flex-wrap items-center justify-between px-4 py-3"
        >
          <span class="text-ink-muted text-ui min-w-0 flex-1">{message}</span>
          <span
            :if={@primary_blocker && elem(@primary_blocker, 0) == key}
            id={"gstr3b-blocker-current-#{key}"}
            class="text-ink-subtle text-ui font-medium"
          >
            Current next step
          </span>

          <.blocker_exit
            :if={is_nil(@primary_blocker) or elem(@primary_blocker, 0) != key}
            blocker={{key, message, exit}}
            id={"gstr3b-blocker-action-#{key}"}
            variant="outline"
            size="xs"
          />
        </li>
      </ul>
    </section>
    """
  end

  attr :gstr3b, :any, required: true
  attr :itc, :any, default: nil
  attr :stats, :any, required: true
  attr :signed, :boolean, default: false
  attr :open_folds, :any, default: MapSet.new()
  attr :gstr3b_signoff, :any, default: nil
  attr :client_id, :string, default: nil
  attr :period, :string, default: nil

  def gstr3b_controls(assigns) do
    current_itc = current_proposed_itc(assigns.gstr3b, assigns.itc, assigns.signed)
    assembled_itc = heads_total(assigns.gstr3b["itc"]["net_itc_4c"])

    pending_reason =
      projection_pending_reason(assigns.gstr3b, assigns.itc, assigns.stats, assigns.signed)

    filing_ready = is_nil(pending_reason)

    assigns =
      assigns
      |> assign(:current_itc, current_itc)
      |> assign(:assembled_itc, assembled_itc)
      |> assign(:pending_reason, pending_reason)
      |> assign(:filing_ready, filing_ready)
      |> assign(:setoff_rows, if(filing_ready, do: setoff_rows(assigns.gstr3b), else: []))

    ~H"""
    <section id="gstr3b-controls" class="space-y-block scroll-mt-28">
      <div>
        <h3 class="text-base-content text-h4 font-semibold">Return controls</h3>

        <p class="text-ink-muted text-ui">The sources and arithmetic that assemble this GSTR-3B.</p>
      </div>

      <div class="bg-panel-surface border-rule divide-rule rounded-box divide-y border">
        <.fold
          id="gstr3b-control-outward"
          open={MapSet.member?(@open_folds, "gstr3b-control-outward")}
          class="px-4"
          summary_class="py-4 text-base-content w-full"
        >
          <:summary>
            <.fold_summary title="Outward liability source">
              <:detail>{outward_source(@gstr3b)}</:detail>

              <:status>
                <.badge variant={if liability_missing?(@gstr3b), do: "warning", else: "neutral"}>
                  {if liability_missing?(@gstr3b), do: "Pending", else: "Derived"}
                </.badge>
              </:status>
            </.fold_summary>
          </:summary>

          <div class="grid gap-4 pb-4 sm:grid-cols-4">
            <.head_fact label="Taxable" amount={get_in(@gstr3b, ["liability_31", "a", "txval"])} />
            <.head_fact label="IGST" amount={get_in(@gstr3b, ["liability_31", "a", "igst"])} />
            <.head_fact label="CGST" amount={get_in(@gstr3b, ["liability_31", "a", "cgst"])} />
            <.head_fact label="SGST" amount={get_in(@gstr3b, ["liability_31", "a", "sgst"])} />
          </div>
        </.fold>

        <.fold
          id="gstr3b-control-itc"
          open={MapSet.member?(@open_folds, "gstr3b-control-itc")}
          class="px-4"
          summary_class="py-4 text-base-content w-full"
        >
          <:summary>
            <.fold_summary title="Net ITC source">
              <:detail>
                {if @signed,
                  do: "Frozen purchase position",
                  else: "Current purchase and GSTR-2B position"}
              </:detail>

              <:status>
                <.badge variant={if @pending_reason && not @signed, do: "warning", else: "neutral"}>
                  {if @pending_reason && not @signed, do: "Provisional", else: "Derived"}
                </.badge>
              </:status>
            </.fold_summary>
          </:summary>

          <div class="space-y-related pb-4">
            <p class="text-ink-muted text-ui">
              {if @signed, do: "Frozen net ITC in Table 4C", else: "Current claimable ITC"}:
              <span id="gstr3b-control-current-itc" class="text-base-content font-mono font-semibold">
                {money_paise(@current_itc)}
              </span>
            </p>

            <p
              :if={not @signed and @current_itc != @assembled_itc}
              id="gstr3b-itc-provisional-difference"
              class="nila-gstr3b-provisional text-ui"
            >
              The assembled Table 4C currently shows {money_paise(@assembled_itc)}. It remains provisional until the purchase inputs are resolved.
            </p>

            <.link
              :if={@client_id && @period}
              id="gstr3b-open-purchases"
              patch={~p"/gst/#{@client_id}/#{@period}?track=purchases"}
              class="text-moon text-ui font-semibold"
            >
              Open Purchases &amp; ITC →
            </.link>
          </div>
        </.fold>

        <.fold
          id="gstr3b-control-filing-lines"
          open={MapSet.member?(@open_folds, "gstr3b-control-filing-lines")}
          class="px-4"
          summary_class="py-4 text-base-content w-full"
        >
          <:summary>
            <.fold_summary title="GSTR-3B filing-line mapping">
              <:detail>3.1 liability and Table 4 credit by tax head</:detail>

              <:status>
                <.badge variant={if @filing_ready, do: "neutral", else: "warning"}>
                  {if @filing_ready, do: "Derived", else: "Pending inputs"}
                </.badge>
              </:status>
            </.fold_summary>
          </:summary>

          <div class="pb-4">
            <.data_table
              :if={@filing_ready}
              id="gst-3b-filing-detail"
              rows={gstr3b_rows(@gstr3b)}
              row_id={&"gst-3b-row-#{&1.key}"}
              min_width="min-w-[640px]"
              mode="scan"
            >
              <:col :let={row} label="GSTR-3B section" row_header>
                <span class={row.strong? && "text-base-content font-semibold"}>{row.label}</span>
              </:col>

              <:col :let={row} label="IGST" align="right">{head_money(row, "igst")}</:col>

              <:col :let={row} label="CGST" align="right">{head_money(row, "cgst")}</:col>

              <:col :let={row} label="SGST" align="right">{head_money(row, "sgst")}</:col>

              <:col :let={row} label="Total" align="right">
                <span class={row.strong? && "text-base-content font-semibold"}>{row_total(row)}</span>
              </:col>
            </.data_table>

            <p
              :if={not @filing_ready}
              id="gst-3b-filing-detail-pending"
              class="text-ink-muted text-ui"
            >
              {@pending_reason}
            </p>
          </div>
        </.fold>

        <.fold
          id="gstr3b-control-setoff"
          open={MapSet.member?(@open_folds, "gstr3b-control-setoff")}
          class="px-4"
          summary_class="py-4 text-base-content w-full"
        >
          <:summary>
            <.fold_summary title="Rule 88A set-off and cash">
              <:detail>Credit used and residual cash by liability head</:detail>

              <:status>
                <.badge variant={if @filing_ready, do: "neutral", else: "warning"}>
                  {if @filing_ready, do: "Calculated", else: "Pending inputs"}
                </.badge>
              </:status>
            </.fold_summary>
          </:summary>

          <div class="pb-4">
            <.data_table
              :if={@setoff_rows != []}
              id="gst-3b-setoff-detail"
              rows={@setoff_rows}
              row_id={&"gst-3b-setoff-#{&1.key}"}
              min_width="min-w-[720px]"
              mode="scan"
            >
              <:col :let={row} label="Liability head" row_header>
                <span class="text-base-content font-semibold">{row.label}</span>
              </:col>

              <:col :let={row} label="Payable" align="right">{money_paise(row.payable)}</:col>

              <:col :let={row} label="IGST credit" align="right">{money_paise(row.itc_igst)}</:col>

              <:col :let={row} label="CGST credit" align="right">{money_paise(row.itc_cgst)}</:col>

              <:col :let={row} label="SGST credit" align="right">{money_paise(row.itc_sgst)}</:col>

              <:col :let={row} label="Cash" align="right">
                <span class="text-base-content font-semibold">{money_paise(row.cash)}</span>
              </:col>
            </.data_table>

            <p :if={not @filing_ready} id="gst-3b-setoff-pending" class="text-ink-muted text-ui">
              {@pending_reason}
            </p>

            <p :if={@filing_ready and @setoff_rows == []} class="text-ink-muted text-ui">
              No per-head set-off schedule is available in this return projection.
            </p>
          </div>
        </.fold>
      </div>

      <section
        id="gstr3b-source-references"
        class="border-rule rounded-box space-y-related border p-4"
      >
        <h4 class="text-base-content text-ui font-semibold">Source snapshots</h4>

        <dl class="grid gap-4 sm:grid-cols-2">
          <div>
            <dt class="text-ink-subtle text-label uppercase">GSTR-1</dt><dd class="text-base-content text-ui wrap-break-word">
              {outward_source(@gstr3b)}
            </dd>
          </div>

          <div>
            <dt class="text-ink-subtle text-label uppercase">Purchase position</dt><dd class="text-base-content text-ui wrap-break-word">
              {purchase_snapshot_reference(@gstr3b_signoff)}
            </dd>
          </div>
        </dl>
      </section>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :amount, :any, default: 0

  defp head_fact(assigns) do
    ~H"""
    <div>
      <p class="text-ink-subtle text-label uppercase">{@label}</p><p class="text-base-content text-ui font-mono font-semibold">
        {money_paise(@amount || 0)}
      </p>
    </div>
    """
  end

  attr :purchase_month, :any, required: true
  attr :sales_month, :any, default: nil
  attr :sales_reviewable, :boolean, default: false
  attr :stats, :any, required: true
  attr :gstr3b_signoff, :any, default: nil
  attr :can_sign_off, :boolean, required: true
  attr :sales_intake_open, :boolean, default: false
  attr :itc, :any, default: nil
  attr :gstr3b, :any, default: nil

  def gstr3b_actions(assigns) do
    assigns = assign(assigns, :blockers, gstr3b_blockers(assigns))

    ~H"""
    <section
      :if={not is_nil(@gstr3b_signoff) or @blockers == []}
      id="month-exit-gstr3b"
      class="bg-panel-surface border-rule rounded-box scroll-mt-28 border p-6"
    >
      <div :if={is_nil(@gstr3b_signoff)} class="space-y-block">
        <div class="gap-block flex flex-wrap items-start justify-between">
          <div class="space-y-1">
            <h3 class="text-base-content text-h4 font-semibold">Sign-off</h3>

            <p :if={@blockers != []} class="text-ink-muted text-ui">
              {length(@blockers)} {plural(length(@blockers), "requirement")} remain before this
              return can be signed.
            </p>

            <p :if={@blockers == [] and @can_sign_off} class="text-ink-muted text-ui">
              The assembled return is ready for your signature.
            </p>

            <p :if={@blockers == [] and not @can_sign_off} class="text-ink-muted text-ui">
              Ready for a senior to sign GSTR-3B.
            </p>
          </div>
        </div>

        <%!-- Three of these are server gates in `Signoffs.sign_off/2` — the
              register, the s.16(2)(a) attestation and the sales intake — and the
              button used to render on the register alone, so the other two failed
              at the click with a flash naming a control on a different page and no
              way to reach it. The remaining three are this page's own filing
              order: the 3B takes its outward liability from the GSTR-1, so it
              waits for one that is approved and filed. The server would accept a
              signature without them; the sequence is ours. --%>
      </div>

      <.signed_return
        :if={@gstr3b_signoff}
        return="GSTR-3B"
        signoff={@gstr3b_signoff}
        month={@purchase_month}
        reopen_event="3b-reopen-signoff"
        reopen_id="gst-reopen-signoff"
        reopen_confirm="Reopen this signed month? The signature is revoked and the month can be worked again."
        can_sign_off={@can_sign_off}
      />
    </section>
    """
  end

  attr :blocker, :any, required: true
  attr :id, :string, required: true
  attr :variant, :string, default: "outline"
  attr :size, :string, default: "sm"

  defp blocker_exit(assigns) do
    {_key, _message, exit} = assigns.blocker
    assigns = assign(assigns, :exit, exit)

    ~H"""
    <.button
      :if={elem(@exit, 0) == :navigate}
      id={@id}
      navigate={elem(@exit, 2)}
      variant={@variant}
      size={@size}
    >
      {elem(@exit, 1)}
    </.button>

    <.button
      :if={elem(@exit, 0) == :patch}
      id={@id}
      patch={elem(@exit, 2)}
      variant={@variant}
      size={@size}
    >
      {elem(@exit, 1)}
    </.button>

    <.button
      :if={elem(@exit, 0) == :click}
      id={@id}
      phx-click={elem(@exit, 2)}
      variant={@variant}
      size={@size}
    >
      {elem(@exit, 1)}
    </.button>

    <.button
      :if={elem(@exit, 0) == :anchor}
      id={@id}
      href={elem(@exit, 2)}
      variant={@variant}
      size={@size}
    >
      {elem(@exit, 1)}
    </.button>
    """
  end

  attr :gstr3b, :any, default: nil
  attr :itc, :any, default: nil
  attr :stats, :any, default: nil
  attr :signed, :boolean, default: false
  slot :primary_action

  def gstr3b_evidence(assigns) do
    ~H"""
    <section
      :if={show_gstr3b_evidence?(@gstr3b, @stats, @signed)}
      id="month-3b"
      class="bg-quiet border-rule rounded-box space-y-block border p-6"
    >
      <div class="flex flex-wrap items-start justify-between gap-4">
        <div class="space-y-related">
          <p class="text-ink-subtle text-label font-semibold uppercase">Final return</p>

          <h3 class="font-display text-base-content text-h3 font-normal">
            {if @signed, do: "Signed GSTR-3B", else: "Proposed GSTR-3B"}
          </h3>

          <p :if={not @signed} id="gstr3b-preview-status" class="text-body text-ink-muted">
            {gstr3b_preview_status(@gstr3b, @stats)}
          </p>
        </div>
         {render_slot(@primary_action)}
      </div>

      <div class="space-y-related">
        <dl
          id="gst-3b-position"
          class="border-rule gap-block py-block grid border-y sm:grid-cols-3"
        >
          <div class="space-y-1">
            <dt class="text-ink-subtle text-label font-semibold uppercase">
              Outward tax · 3.1(a)
            </dt>

            <dd
              :if={not liability_missing?(@gstr3b)}
              class="text-base-content text-lead font-semibold tabular-nums"
            >
              {money_paise(heads_total(@gstr3b["liability_31"]["a"]))}
            </dd>

            <dd :if={liability_missing?(@gstr3b)} class="text-ink-muted text-ui font-medium">
              Pending GSTR-1
            </dd>
          </div>

          <div class="space-y-1">
            <dt class="text-ink-subtle text-label font-semibold uppercase">
              Current proposed ITC
            </dt>

            <dd
              id="gst-3b-current-itc"
              class="text-base-content text-lead font-semibold tabular-nums"
            >
              {money_paise(current_proposed_itc(@gstr3b, @itc, @signed))}
            </dd>
          </div>

          <div class="space-y-1">
            <dt class="text-ink-subtle text-label font-semibold uppercase">Cash payable</dt>

            <dd
              :if={cash_available?(@gstr3b, @itc, @stats, @signed)}
              id="gst-3b-cash"
              class="text-base-content text-lead font-semibold tabular-nums"
            >
              {money_paise(@gstr3b["setoff_61"]["cash_total"])}
            </dd>

            <dd
              :if={not cash_available?(@gstr3b, @itc, @stats, @signed)}
              id="gst-3b-cash-pending"
              class="text-ink-muted text-ui font-medium"
            >
              {projection_pending_reason(@gstr3b, @itc, @stats, @signed)}
            </dd>
          </div>
        </dl>
      </div>
    </section>
    """
  end

  attr :return, :string, required: true
  attr :signoff, :any, required: true
  attr :month, :any, required: true
  attr :reopen_event, :string, required: true
  attr :reopen_id, :string, required: true
  attr :reopen_confirm, :string, required: true
  attr :can_sign_off, :boolean, required: true
  slot :extra_step

  defp signed_return(assigns) do
    ~H"""
    <div class="space-y-block">
      <div class="flex flex-wrap items-center gap-2">
        <span class="text-base-content text-ui font-semibold">{@return}</span>
        <.badge variant="success">{approval_label(@return)}</.badge>
      </div>

      <dl class="gap-block text-ui grid sm:grid-cols-2">
        <div>
          <dt class="text-ink-subtle text-label font-semibold uppercase">
            {if @return == "GSTR-1", do: "Approved by", else: "Signed by"}
          </dt>

          <dd class="text-base-content font-medium">
            {(@signoff.signed_by && @signoff.signed_by.name) || "—"}
          </dd>
        </div>

        <div>
          <dt class="text-ink-subtle text-label font-semibold uppercase">
            {if @return == "GSTR-1", do: "Approved", else: "Signed"}
          </dt>

          <dd class="text-ink-muted">{format_display_datetime(@signoff.inserted_at)}</dd>
        </div>
      </dl>

      <.button
        :if={@can_sign_off and is_nil(@month.filed_at)}
        id={@reopen_id}
        variant="ghost"
        size="xs"
        phx-click={@reopen_event}
        data-confirm={@reopen_confirm}
      >
        Reopen signature
      </.button>
       {render_slot(@extra_step)}
    </div>
    """
  end

  defp approval_label("GSTR-1"), do: "Approved"
  defp approval_label(_return), do: "Signed"

  # `data-confirm` guarded reopening a signature but not giving one, which had
  # the caution exactly backwards. Naming the money in the prompt also means the
  # figures are in front of the signer at the moment of signing even if they
  # never scrolled the summary.

  # The full server gate (`Signoffs.sign_off/2`), each condition paired with the
  # control that clears it. Uncollected bills and vendor amount disputes stay
  # visible as findings and in the money, but neither is answerable here, so
  # neither appears.
  #
  # Every server gate has to be mirrored, not just the ones that are cheap to
  # check here.
  #
  # Every `:anchor` must point at a section that renders in the state its
  # blocker describes. `#month-exit-gstr1` does not: it is gated on the GSTR-1
  # already being reviewable, which is exactly what an unapproved one is not.
  defp gstr3b_blockers(assigns) do
    %{client_id: client_id, period: period} = assigns.purchase_month
    purchase_review = ~p"/gst/#{client_id}/#{period}/review/purchase?scope=needs_you"

    [
      {"decisions", assigns.stats.need_decision > 0,
       "#{assigns.stats.need_decision} purchase #{plural(assigns.stats.need_decision, "decision")} still open.",
       {:patch, "Review decisions", purchase_review}},
      {"cess-treatment",
       (get_in(assigns.itc, ["current_claim_heads", "cess"]) || 0) != 0 or
         (get_in(assigns.itc, ["later_heads", "cess"]) || 0) != 0,
       "Compensation cess needs separate review; Nila cannot sign off a cess claim or deferral.",
       {:navigate, "Review ITC treatment",
        ~p"/gst/#{client_id}/#{period}/purchases/register?filter=treatment"}},
      {"itc-treatment", (assigns.itc["pending_paise"] || 0) > 0,
       "Some credit still needs an ITC treatment decision.",
       {:navigate, "Set ITC treatment",
        ~p"/gst/#{client_id}/#{period}/purchases/register?filter=treatment"}},
      {"attestation", assigns.stats.need_decision == 0 and attestation_open?(assigns.itc),
       "Nobody has confirmed whether the client holds tax invoices for the supplies the portal reported (s.16(2)(a)).",
       {:patch, "Answer it", purchase_review}},
      {"no-sales", is_nil(assigns.sales_month),
       "GSTR-1 is not ready, so outward liability and cash payable are still pending.",
       {:navigate, "Bring in sales bills",
        ~p"/gst/upload?client_id=#{client_id}&period=#{period}"}},
      {"r1-unreviewed",
       not is_nil(assigns.sales_month) and is_nil(assigns.sales_month.filed_at) and
         not Map.get(assigns, :sales_reviewable, Map.get(assigns, :reviewable, false)),
       "Resolve the open sales checks before signing the GSTR-3B.",
       {:patch, "Go to the GSTR-1", month_track_path(client_id, period, :sales)}},
      {"sales-intake", assigns.sales_intake_open,
       "A supplied sales packet is still unresolved, so the outward liability may be incomplete.",
       {:patch, "Review the packet", month_track_path(client_id, period, :sales)}},
      {"negative-liability", Gstr3b.negative_outward_liability?(assigns.gstr3b),
       "Credit notes exceed this month's supported outward liability. Nila can calculate the reduction but does not yet file the resulting negative GSTR-3B position.",
       {:none, nil, nil}}
    ]
    |> Enum.filter(fn {_key, active?, _message, _exit} -> active? end)
    |> Enum.map(fn {key, _active?, message, exit} -> {key, message, exit} end)
  end

  # Required and not yet answered. `documents_attested` alone cannot say this:
  # it is `nil` both when no supply needs attesting and when one does and nobody
  # has answered, so keying off `"unknown"` left the commonest blocked state —
  # a fresh month with a 2B-only supply — rendering the sign button over a gate
  # the server refuses.
  def gstr3b_readiness(%{purchase_month: nil}),
    do: %{state: :absent, label: "Not started", variant: "neutral"}

  def gstr3b_readiness(assigns) do
    blockers = gstr3b_blockers(assigns)

    cond do
      not is_nil(assigns.purchase_month.filed_at) ->
        %{state: :filed, label: "Filed", variant: "neutral"}

      not is_nil(assigns.gstr3b_signoff) ->
        %{state: :signed, label: "Signed · not filed", variant: "info"}

      blockers != [] ->
        %{state: :blocked, label: "Blocked", variant: "warning"}

      assigns.can_sign_off ->
        %{state: :ready, label: "Ready to sign", variant: "success"}

      true ->
        %{state: :awaiting_senior, label: "Awaiting senior", variant: "info"}
    end
  end

  defp month_track_path(client_id, period, :sales),
    do: "/gst/#{client_id}/#{period}/sales"

  defp attestation_open?(%{"attestation_required" => true} = itc),
    do: itc["documents_attested"] not in ~w(held not_held per_case)

  defp attestation_open?(_itc), do: false

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"
  defp plural(1, singular, _plural), do: singular
  defp plural(_count, _singular, plural), do: plural

  defp outward_source(%{"liability_source" => "gstr1_filed"}), do: "Filed GSTR-1 position"
  defp outward_source(%{"liability_source" => "gstr1_reviewed"}), do: "Reviewed GSTR-1 position"
  defp outward_source(%{"liability_source" => "gstr1_derived"}), do: "Current derived GSTR-1"
  defp outward_source(%{"liability_source" => "missing"}), do: "GSTR-1 liability not available"
  defp outward_source(_gstr3b), do: "Current outward-liability projection"

  defp purchase_snapshot_reference(%{inserted_at: inserted_at}),
    do: "Frozen at GSTR-3B sign-off · #{format_display_datetime(inserted_at)}"

  defp purchase_snapshot_reference(_signoff), do: "Current effective purchase and ITC position"

  defp setoff_rows(%{"setoff_61" => %{"other" => other, "rcm" => rcm}})
       when is_map(other) and is_map(rcm) do
    heads = [{"igst", "IGST"}, {"cgst", "CGST"}, {"sgst", "SGST"}]

    ordinary =
      Enum.map(heads, fn {key, label} ->
        row = other[key] || %{}

        %{
          key: key,
          label: label,
          payable: row["payable"] || 0,
          itc_igst: row["itc_igst"] || 0,
          itc_cgst: row["itc_cgst"] || 0,
          itc_sgst: row["itc_sgst"] || 0,
          cash: row["cash"] || 0
        }
      end)

    rcm_rows =
      for {key, label} <- heads,
          row = rcm[key] || %{},
          (row["payable"] || 0) != 0 do
        %{
          key: "rcm-#{key}",
          label: "RCM #{label}",
          payable: row["payable"] || 0,
          itc_igst: 0,
          itc_cgst: 0,
          itc_sgst: 0,
          cash: row["cash"] || 0
        }
      end

    ordinary ++ rcm_rows
  end

  defp setoff_rows(_gstr3b), do: []

  defp current_proposed_itc(gstr3b, itc, signed?) do
    cond do
      signed? -> heads_total(gstr3b["itc"]["net_itc_4c"])
      is_map(itc) and is_number(itc["claimable_paise"]) -> itc["claimable_paise"]
      true -> heads_total(gstr3b["itc"]["net_itc_4c"])
    end
  end

  defp cash_available?(gstr3b, itc, stats, signed?),
    do: is_nil(projection_pending_reason(gstr3b, itc, stats, signed?))

  defp projection_pending_reason(_gstr3b, _itc, _stats, true), do: nil

  defp projection_pending_reason(%{"liability_source" => "missing"}, _itc, _stats, false),
    do: "Pending outward tax from GSTR-1"

  defp projection_pending_reason(_gstr3b, _itc, %{need_decision: count}, false)
       when count > 0,
       do: "#{count} purchase #{plural(count, "input")} remain"

  defp projection_pending_reason(gstr3b, itc, _stats, false) do
    current = current_proposed_itc(gstr3b, itc, false)
    assembled = heads_total(gstr3b["itc"]["net_itc_4c"])

    if current == assembled,
      do: nil,
      else: "Current claimable ITC does not yet equal the assembled Table 4C"
  end

  defp gstr3b_rows(gstr3b) do
    itc = gstr3b["itc"]

    [
      filing_row("31a", "3.1(a) Taxable outward supplies", gstr3b["liability_31"]["a"]),
      filing_row("31d", "3.1(d) Reverse-charge liability", gstr3b["liability_31"]["d"]),
      filing_row(
        "4a",
        "4A Eligible ITC",
        ItcPosition.sum_heads([itc["rcm_4a3"], itc["all_other_itc_4a5"]])
      ),
      filing_row("4b", "4B Reversals", sum_4b(itc), negative?: true),
      filing_row("4c", "4C Net ITC", itc["net_itc_4c"], strong?: true)
    ]
  end

  defp filing_row(key, label, heads, opts \\ []) do
    %{
      key: key,
      label: label,
      heads: heads,
      negative?: Keyword.get(opts, :negative?, false),
      strong?: Keyword.get(opts, :strong?, false)
    }
  end

  defp head_money(row, head), do: signed_head_money(row.heads[head] || 0, row.negative?)
  defp row_total(row), do: signed_head_money(heads_total(row.heads), row.negative?)

  defp signed_head_money(paise, true) when paise > 0, do: "−" <> money_paise(paise)
  defp signed_head_money(paise, _negative?), do: money_paise(paise)

  defp show_gstr3b_evidence?(nil, _stats, _signed), do: false
  defp show_gstr3b_evidence?(_gstr3b, _stats, _signed), do: true

  defp gstr3b_preview_status(%{"liability_source" => "missing"}, %{need_decision: count})
       when count > 0,
       do: "Provisional · #{count} purchase #{plural(count, "decision")} may change ITC"

  defp gstr3b_preview_status(_gstr3b, %{need_decision: count}) when count > 0,
    do: "Provisional · #{count} purchase #{plural(count, "decision")} may change ITC"

  defp gstr3b_preview_status(gstr3b, _stats) do
    if liability_missing?(gstr3b),
      do: "Outward liability pending · GSTR-1 has not been prepared",
      else: "Current draft"
  end

  defp liability_missing?(gstr3b), do: gstr3b["liability_source"] == "missing"
  defp heads_total(heads), do: (heads["igst"] || 0) + (heads["cgst"] || 0) + (heads["sgst"] || 0)
  defp sum_4b(itc), do: ItcPosition.sum_heads([itc["reversed_4b1"], itc["reversed_4b2"]])
  defp money_paise(paise), do: Nila.Formatters.format_money_with_paise(paise || 0)
end
