defmodule NilaWeb.Components.Gst.Month.Filing do
  use NilaWeb, :html

  @moduledoc """
  The exit block: both returns' signatures, the portal steps, and the assembled
  3B.

  It is never a second door. The one saturated control on the page is the
  verdict's door at the top, and in a sign state that door *is* the sign
  action. What lives down here is only its consequences: the reason a
  signature is still blocked, the ARN entry once a return is signed (the one
  state whose actionable control belongs at the exit), and the closed record
  after filing. The page ends at *filed*, not at signed.
  """

  alias Nila.Gst.Filing.ItcPosition

  attr :purchase_month, :any, default: nil
  attr :sales_month, :any, default: nil
  attr :stats, :any, default: nil
  attr :gstr3b, :any, default: nil
  attr :gstr3b_signoff, :any, default: nil
  attr :r1_signoff, :any, default: nil
  attr :open_issue_count, :integer, default: 0
  attr :can_sign_off, :boolean, required: true
  attr :open_folds, :any, default: MapSet.new()

  def exit_block(assigns) do
    ~H"""
    <section
      :if={@purchase_month || @sales_month}
      id="month-exit"
      class="border-base-300 space-y-4 border-t pt-6"
    >
      <h2 class="text-eyebrow text-moon font-semibold uppercase">Signatures and filing</h2>

      <div :if={@sales_month} id="month-exit-gstr1" class="scroll-mt-28">
        <.return_state
          return="GSTR-1"
          signoff={@r1_signoff}
          month={@sales_month}
          blocked_reason={r1_blocked_reason(assigns)}
          reopen_event="r1-reopen-signoff"
          reopen_id="gstr1-reopen-signoff"
          reopen_confirm="Reopen this signed GSTR-1? The signature is revoked, and any GSTR-3B signed against it is reopened too."
          filed_event="r1-mark-filed"
          form_id="gstr1-mark-filed"
          arn_id="gstr1-filed-arn"
          blocked_id="gstr1-signoff-blocked"
          filed_note_id="gstr1-filed-note"
          can_sign_off={@can_sign_off}
        >
          <:extra_step>
            <li class="text-small flex flex-wrap items-center gap-2">
              <span class="text-base-content/70 font-mono">1.</span>
              <span class="text-base-content flex-1">Download the portal JSON</span>
              <.button
                id="gstr1-guide-download-json"
                href={~p"/gstr1/#{@sales_month.client_id}/#{@sales_month.period}/return.json"}
                variant="outline"
                size="xs"
              >
                Download JSON
              </.button>
            </li>
          </:extra_step>
        </.return_state>
      </div>

      <div :if={@purchase_month} id="month-exit-gstr3b" class="scroll-mt-28">
        <.return_state
          return="GSTR-3B"
          signoff={@gstr3b_signoff}
          month={@purchase_month}
          blocked_reason={gstr3b_blocked_reason(assigns)}
          reopen_event="3b-reopen-signoff"
          reopen_id="gst-reopen-signoff"
          reopen_confirm="Reopen this signed month? The signature is revoked and the month can be worked again."
          filed_event="3b-mark-filed"
          form_id="gst-mark-filed"
          arn_id="gst-filed-arn"
          blocked_id="gst-signoff-blocked"
          filed_note_id="gst-filed-note"
          can_sign_off={@can_sign_off}
        />
      </div>

      <.fold :if={@gstr3b} id="month-3b" open={MapSet.member?(@open_folds, "month-3b")}>
        <:summary>
          <.icon name="hero-document-text" class="text-base-content/40 size-4 shrink-0" />
          <span class="flex-1">The assembled GSTR-3B</span>
        </:summary>
        <.gstr3b_panel gstr3b={@gstr3b} />
      </.fold>
    </section>
    """
  end

  attr :return, :string, required: true
  attr :signoff, :any, default: nil
  attr :month, :any, required: true
  attr :blocked_reason, :any, default: nil
  attr :reopen_event, :string, required: true
  attr :reopen_id, :string, required: true
  attr :reopen_confirm, :string, required: true
  attr :filed_event, :string, required: true
  attr :form_id, :string, required: true
  attr :arn_id, :string, required: true
  attr :blocked_id, :string, required: true
  attr :filed_note_id, :string, required: true
  attr :can_sign_off, :boolean, required: true
  slot :extra_step

  defp return_state(assigns) do
    ~H"""
    <p
      :if={is_nil(@signoff) and @blocked_reason}
      id={@blocked_id}
      class="text-base-content/70 text-small"
    >
      {@return} signature waits: {@blocked_reason}
    </p>

    <p
      :if={is_nil(@signoff) and is_nil(@blocked_reason)}
      class="text-base-content/70 text-small"
    >
      {@return} is ready for a signature.
    </p>

    <div :if={@signoff} class="space-y-3">
      <div class="flex items-start gap-2">
        <.icon name="hero-check-badge" class="text-success size-5 shrink-0" />
        <p class="text-base-content text-small flex-1">
          {@return} signed off by {(@signoff.signed_by && @signoff.signed_by.name) || "—"} · {format_display_datetime(
            @signoff.inserted_at
          )}. Figures are frozen as approved.
          <span :if={@month.filed_at} id={@filed_note_id} class="font-medium">
            Filed {format_display_datetime(@month.filed_at)}{if @month.filing_arn,
              do: " · ARN #{@month.filing_arn}"}.
          </span>
        </p>
        <.button
          :if={@can_sign_off and is_nil(@month.filed_at)}
          id={@reopen_id}
          variant="ghost"
          size="xs"
          phx-click={@reopen_event}
          data-confirm={@reopen_confirm}
        >
          Reopen
        </.button>
      </div>

      <ol :if={is_nil(@month.filed_at)} class="space-y-2 pl-7">
        {render_slot(@extra_step)}
        <li class="text-small flex items-center gap-2">
          <span class="text-base-content/70 font-mono">{if @extra_step != [], do: "2.", else: "1."}</span>
          <span class="text-base-content flex-1">File it at gst.gov.in</span>
          <a
            href="https://www.gst.gov.in/"
            target="_blank"
            rel="noopener"
            class="text-moon font-semibold"
          >
            Open portal →
          </a>
        </li>
        <li>
          <form
            id={@form_id}
            phx-submit={@filed_event}
            class="text-small flex flex-wrap items-center gap-2"
          >
            <span class="text-base-content/70 font-mono">{if @extra_step != [], do: "3.", else: "2."}</span>
            <span class="text-base-content flex-1">Paste the ARN here</span>
            <.input
              type="text"
              name="arn"
              id={@arn_id}
              value=""
              placeholder="ARN (optional)"
              class="input input-sm w-40 font-mono"
            />
            <.button type="submit" variant="outline" size="xs">Filed on portal</.button>
          </form>
        </li>
      </ol>
    </div>
    """
  end

  # Named, not counted. The headline, the door and the section fold have all
  # already said how many; a fourth count at the foot of the page, where nothing
  # can be done about it, is the verdict restated. What the exit owes the reader
  # is only *which* gate is shut.
  defp r1_blocked_reason(%{sales_month: sales, open_issue_count: open}) do
    cond do
      is_nil(sales) -> "the sales bills are not in"
      open > 0 -> "the GSTR-1 still has issues to check"
      sales.state != "reviewed" -> "the GSTR-1 is not marked reviewed yet"
      true -> nil
    end
  end

  defp gstr3b_blocked_reason(assigns) do
    [
      assigns.stats && assigns.stats.need_decision > 0 && "the purchases are not all decided",
      assigns.sales_month == nil && "the sales bills"
    ]
    |> Enum.filter(& &1)
    |> case do
      [] -> nil
      reasons -> Enum.join(reasons, ", ")
    end
  end

  attr :gstr3b, :map, required: true

  defp gstr3b_panel(assigns) do
    ~H"""
    <div id="gst-3b-panel" class="border-base-300 rounded-box mt-3 border">
      <div class="border-base-300 flex items-center justify-between border-b px-4 py-3">
        <div class="text-base-content/70 text-small">
          {if liability_missing?(@gstr3b),
            do: "ITC side assembled. Outward liability needs the month's sales bills.",
            else: "Assembled from the worked sales month and the 2B reconciliation."}
        </div>
        <div :if={!liability_missing?(@gstr3b)} class="text-right">
          <div class="text-base-content/60 text-label font-semibold uppercase">Cash payable</div>
          <%!-- The only figure in the whole flow that leaves the client's bank
                account, so it is set as a figure — display face, tabular — not
                as body text in a third typeface. --%>
          <div
            id="gst-3b-cash"
            class="font-display text-base-content text-h3 leading-none font-normal tabular-nums"
          >
            {money_paise(@gstr3b["setoff_61"]["cash_total"])}
          </div>
        </div>
      </div>

      <div class="grid gap-x-6 gap-y-2 px-4 py-3 sm:grid-cols-2">
        <div :if={!liability_missing?(@gstr3b)} class="space-y-1.5">
          <div class="text-base-content/60 text-label font-semibold uppercase">
            3.1 Outward liability
          </div>
          <.gstr3b_line label="(a) Taxable supplies" heads={@gstr3b["liability_31"]["a"]} />
          <.gstr3b_line label="(d) Reverse charge" heads={@gstr3b["liability_31"]["d"]} />
        </div>
        <div :if={liability_missing?(@gstr3b)} class="space-y-1.5">
          <div class="text-base-content/60 text-label font-semibold uppercase">
            3.1 Outward liability
          </div>
          <p class="text-base-content/70 text-small">
            No worked sales month for this period yet. Upload the sales bills to derive the GSTR-1 and complete the return.
          </p>
          <.gstr3b_line label="(d) Reverse charge" heads={@gstr3b["liability_31"]["d"]} />
        </div>
        <div class="space-y-1.5">
          <div class="text-base-content/60 text-label font-semibold uppercase">4. Eligible ITC</div>
          <.gstr3b_line label="A(3) Reverse charge credit" heads={@gstr3b["itc"]["rcm_4a3"]} />
          <.gstr3b_line label="A(5) All other ITC" heads={@gstr3b["itc"]["all_other_itc_4a5"]} />
          <.gstr3b_line label="B Reversed (confirmed blocks)" heads={sum_4b(@gstr3b["itc"])} negative />
          <.gstr3b_line label="C Net ITC" heads={@gstr3b["itc"]["net_itc_4c"]} strong />
        </div>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :heads, :map, required: true
  attr :negative, :boolean, default: false
  attr :strong, :boolean, default: false

  defp gstr3b_line(assigns) do
    ~H"""
    <div class="flex items-baseline justify-between gap-3">
      <span class={[
        "text-small",
        (@strong && "text-base-content font-medium") || "text-base-content/70"
      ]}>
        {@label}
      </span>
      <span class={[
        "text-small font-mono",
        @negative && "text-error",
        !@negative && ((@strong && "text-base-content font-semibold") || "text-base-content/70")
      ]}>
        {if @negative, do: "−"}{money_paise(heads_total(@heads))}
      </span>
    </div>
    """
  end

  defp liability_missing?(gstr3b), do: gstr3b["liability_source"] == "missing"
  defp heads_total(heads), do: (heads["igst"] || 0) + (heads["cgst"] || 0) + (heads["sgst"] || 0)
  defp sum_4b(itc), do: ItcPosition.sum_heads([itc["reversed_4b1"], itc["reversed_4b2"]])
  defp money_paise(paise), do: Nila.Formatters.format_money_with_paise(paise || 0)
end
