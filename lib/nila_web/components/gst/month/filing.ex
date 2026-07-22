defmodule NilaWeb.Components.Gst.Month.Filing do
  use NilaWeb, :html

  @moduledoc "GSTR-3B filing presentation for the GST month workbench."

  alias Nila.Gst.Filing.ItcPosition

  attr :purchase_month, :any, default: nil
  attr :sales_month, :any, default: nil
  attr :stats, :any, default: nil
  attr :gstr3b, :any, default: nil
  attr :gstr3b_signoff, :any, default: nil
  attr :can_sign_off, :boolean, required: true

  def gstr3b_section(assigns) do
    ~H"""
    <section :if={@purchase_month} id="month-3b" class="scroll-mt-28 space-y-4">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <h2 class="text-base-content font-semibold">GSTR-3B — ITC and tax payable</h2>
        <.button
          :if={
            @purchase_month.state == "worked" and @can_sign_off and @stats.need_decision == 0 and
              @sales_month != nil
          }
          id="gst-signoff-button"
          variant="primary"
          size="sm"
          phx-click="3b-sign-off"
        >
          <.icon name="hero-check-badge-mini" class="size-4" /> Sign off month
        </.button>
        <span
          :if={
            @purchase_month.state == "worked" and @can_sign_off and
              (@stats.need_decision > 0 or @sales_month == nil)
          }
          id="gst-signoff-blocked"
          class="text-base-content/60 text-small"
        >
          Sign-off waits — {signoff_blockers(assigns)}
        </span>
      </div>

      <div
        :if={@gstr3b_signoff}
        id="gst-signoff-banner"
        class="bg-success/[0.04] border-success/40 rounded-box space-y-3 border px-4 py-3"
      >
        <div class="flex items-start gap-2">
          <.icon name="hero-check-badge" class="text-success size-5 shrink-0" />
          <p class="text-base-content text-small flex-1">
            Signed off by {(@gstr3b_signoff.signed_by && @gstr3b_signoff.signed_by.name) || "—"} · {format_display_datetime(
              @gstr3b_signoff.inserted_at
            )} — figures are frozen as approved.
            <span :if={@purchase_month.filed_at} id="gst-filed-note" class="font-medium">
              Filed {format_display_datetime(@purchase_month.filed_at)}{if @purchase_month.filing_arn,
                do: " · ARN #{@purchase_month.filing_arn}"}.
            </span>
          </p>
          <.button
            :if={@can_sign_off and is_nil(@purchase_month.filed_at)}
            id="gst-reopen-signoff"
            variant="ghost"
            size="xs"
            phx-click="3b-reopen-signoff"
            data-confirm="Reopen this signed month? The signature is revoked and the month can be worked again."
          >
            Reopen
          </.button>
        </div>

        <ol :if={is_nil(@purchase_month.filed_at)} class="space-y-2 pl-7">
          <li class="text-small flex items-center gap-2">
            <span class="text-base-content/50 font-mono">1.</span>
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
              id="gst-mark-filed"
              phx-submit="3b-mark-filed"
              class="text-small flex flex-wrap items-center gap-2"
            >
              <span class="text-base-content/50 font-mono">2.</span>
              <span class="text-base-content flex-1">Paste the ARN here</span>
              <.input
                type="text"
                name="arn"
                id="gst-filed-arn"
                value=""
                placeholder="ARN (optional)"
                class="input input-sm w-40 font-mono"
                autofocus
              />
              <.button type="submit" variant="success" size="xs">Filed on portal</.button>
            </form>
          </li>
        </ol>
      </div>

      <.gstr3b_panel gstr3b={@gstr3b} />
    </section>
    """
  end

  attr :gstr3b, :map, required: true

  defp gstr3b_panel(assigns) do
    ~H"""
    <div id="gst-3b-panel" class="border-base-300 rounded-box border">
      <div class="border-base-300 flex items-center justify-between border-b px-4 py-3">
        <div class="text-base-content/50 text-fine">
          {if liability_missing?(@gstr3b),
            do: "ITC side assembled — outward liability needs the month's sales bills",
            else: "Assembled from the worked sales month and the 2B reconciliation"}
        </div>
        <div :if={!liability_missing?(@gstr3b)} class="text-right">
          <div class="text-base-content/60 text-label font-medium uppercase">Cash payable</div>
          <div id="gst-3b-cash" class="text-base-content text-lead font-mono font-semibold">
            {money_paise(@gstr3b["setoff_61"]["cash_total"])}
          </div>
        </div>
      </div>

      <div class="grid gap-x-6 gap-y-2 px-4 py-3 sm:grid-cols-2">
        <div :if={!liability_missing?(@gstr3b)} class="space-y-1.5">
          <div class="text-base-content/40 text-fine uppercase">3.1 Outward liability</div>
          <.gstr3b_line label="(a) Taxable supplies" heads={@gstr3b["liability_31"]["a"]} />
          <.gstr3b_line label="(d) Reverse charge" heads={@gstr3b["liability_31"]["d"]} />
        </div>
        <div :if={liability_missing?(@gstr3b)} class="space-y-1.5">
          <div class="text-base-content/40 text-fine uppercase">3.1 Outward liability</div>
          <p class="text-base-content/50 text-small">
            No worked sales month for this period yet — upload the sales bills to derive GSTR-1 and complete the return.
          </p>
          <.gstr3b_line label="(d) Reverse charge" heads={@gstr3b["liability_31"]["d"]} />
        </div>
        <div class="space-y-1.5">
          <div class="text-base-content/40 text-fine uppercase">4. Eligible ITC</div>
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
        !@negative && ((@strong && "text-base-content font-semibold") || "text-base-content/80")
      ]}>
        {if @negative, do: "−"}{money_paise(heads_total(@heads))}
      </span>
    </div>
    """
  end

  defp signoff_blockers(assigns) do
    [
      assigns.stats.need_decision > 0 && "#{assigns.stats.need_decision} purchases to decide",
      assigns.sales_month == nil && "the sales bills"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  defp liability_missing?(gstr3b), do: gstr3b["liability_source"] == "missing"
  defp heads_total(heads), do: (heads["igst"] || 0) + (heads["cgst"] || 0) + (heads["sgst"] || 0)
  defp sum_4b(itc), do: ItcPosition.sum_heads([itc["reversed_4b1"], itc["reversed_4b2"]])
  defp money_paise(paise), do: Nila.Formatters.format_money_with_paise(paise || 0)
end
