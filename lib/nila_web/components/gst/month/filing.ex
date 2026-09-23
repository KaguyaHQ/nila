defmodule NilaWeb.Components.Gst.Month.Filing do
  use NilaWeb, :html

  @moduledoc "Audited return actions rendered directly after their evidence."

  alias Nila.Gst.Filing.WinmanGstr1
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

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"
  defp plural(1, singular, _plural), do: singular
  defp plural(_count, _singular, plural), do: plural
end
