defmodule NilaWeb.Components.Gst.Month.Filing do
  use NilaWeb, :html

  @moduledoc "Audited return actions rendered directly after their evidence."

  alias Nila.Gst.Filing.ItcPosition
  alias Nila.Gst.Sales.Values
  alias NilaWeb.Components.Gst.Month.Helpers

  attr :sales_month, :any, required: true
  attr :r1_signoff, :any, default: nil
  attr :open_issue_count, :integer, required: true
  attr :reviewable, :boolean, required: true
  attr :completeness, :atom, required: true
  attr :can_sign_off, :boolean, required: true
  attr :derived, :any, default: nil

  def gstr1_actions(assigns) do
    assigns = assign(assigns, :filed, assigns.derived && Values.filed_totals(assigns.derived))

    ~H"""
    <section
      :if={gstr1_actionable?(assigns)}
      id="month-exit-gstr1"
      class="border-base-300 pt-block scroll-mt-28 border-t"
    >
      <div
        :if={is_nil(@r1_signoff) and @reviewable and @completeness == :complete}
        class="space-y-related"
      >
        <div class="text-base-content text-body font-medium">GSTR-1 ready for approval</div>
        <ul class="text-ink-muted text-ui space-y-1">
          <li>All checks resolved</li>
          <li>All supplied sales documents accounted for</li>
          <li>Table 12 reconciled</li>
        </ul>
        <%!-- The figures, at the button. Three assurance strings and no rupees
              is not a return: a senior could approve having seen only "all
              checks resolved", with the section-by-section numbers hundreds of
              lines further down a page they may never have scrolled. --%>
        <p :if={@filed} id="month-exit-gstr1-amount" class="text-base-content text-ui">
          Filing <span class="font-mono font-semibold">{Helpers.rupees(@filed.taxable)}</span>
          taxable and <span class="font-mono font-semibold">{Helpers.rupees(@filed.tax)}</span>
          output tax.
        </p>
        <.button
          :if={@can_sign_off}
          id="month-door-sign-r1"
          variant="primary"
          size="sm"
          phx-click="r1-sign-off"
          data-confirm={approval_confirm(@filed)}
        >
          Approve GSTR-1
        </.button>
        <p :if={not @can_sign_off} class="text-ink-muted text-ui">
          Ready for a senior to approve GSTR-1.
        </p>
      </div>

      <p
        :if={is_nil(@r1_signoff) and @reviewable and @completeness != :complete}
        class="text-ink-muted text-ui"
      >
        All review checks are resolved. Approval waits for current client confirmation.
      </p>

      <.signed_return
        :if={@r1_signoff}
        return="GSTR-1"
        signoff={@r1_signoff}
        month={@sales_month}
        reopen_event="r1-reopen-signoff"
        reopen_id="gstr1-reopen-signoff"
        reopen_confirm="Reopen this signed GSTR-1? The signature is revoked, and any GSTR-3B signed against it is reopened too."
        filed_event="r1-mark-filed"
        form_id="gstr1-mark-filed"
        arn_id="gstr1-filed-arn"
        filed_note_id="gstr1-filed-note"
        can_sign_off={@can_sign_off}
      >
        <:extra_step>
          <div class="space-y-related">
            <p class="text-ink-subtle text-label font-semibold uppercase">Portal return</p>
            <.button
              id="gstr1-guide-download-json"
              href={~p"/gstr1/#{@sales_month.client_id}/#{@sales_month.period}/return.json"}
              variant="outline"
              size="xs"
            >
              Download GST JSON
            </.button>
          </div>
        </:extra_step>
      </.signed_return>
    </section>
    """
  end

  attr :purchase_month, :any, required: true
  attr :sales_month, :any, default: nil
  attr :stats, :any, required: true
  attr :gstr3b_signoff, :any, default: nil
  attr :r1_signoff, :any, default: nil
  attr :can_sign_off, :boolean, required: true
  attr :sales_completeness, :atom, default: :open
  attr :itc, :any, default: nil

  def gstr3b_actions(assigns) do
    assigns = assign(assigns, :blockers, gstr3b_blockers(assigns))

    ~H"""
    <section
      :if={not is_nil(@gstr3b_signoff) or @blockers == [] or @purchase_month.state == "worked"}
      id="month-exit-gstr3b"
      class="border-base-300 pt-block scroll-mt-28 border-t"
    >
      <.button
        :if={is_nil(@gstr3b_signoff) and @blockers == [] and @can_sign_off}
        id="month-door-sign-3b"
        variant="primary"
        size="sm"
        phx-click="3b-sign-off"
      >
        Sign the GSTR-3B
      </.button>

      <p
        :if={is_nil(@gstr3b_signoff) and @blockers == [] and not @can_sign_off}
        class="text-ink-muted text-ui"
      >
        Ready for a senior to sign GSTR-3B.
      </p>

      <%!-- Three of these are server gates in `Signoffs.sign_off/2` — the
            register, the s.16(2)(a) attestation and the sales intake — and the
            button used to render on the register alone, so the other two failed
            at the click with a flash naming a control on a different page and no
            way to reach it. The remaining three are this page's own filing
            order: the 3B takes its outward liability from the GSTR-1, so it
            waits for one that is approved and filed. The server would accept a
            signature without them; the sequence is ours. --%>
      <div :if={is_nil(@gstr3b_signoff) and @blockers != []} id="month-exit-gstr3b-blocked">
        <p class="text-base-content text-ui font-medium">
          Before the GSTR-3B can be signed
        </p>
        <ul class="mt-related space-y-related">
          <li :for={{key, message, exit} <- @blockers} id={"gstr3b-blocker-#{key}"}>
            <span class="text-ink-muted text-ui">{message}</span>
            <.button
              :if={elem(exit, 0) == :navigate}
              navigate={elem(exit, 2)}
              variant="outline"
              size="xs"
            >
              {elem(exit, 1)}
            </.button>
            <.button
              :if={elem(exit, 0) == :patch}
              patch={elem(exit, 2)}
              variant="outline"
              size="xs"
            >
              {elem(exit, 1)}
            </.button>
            <.button
              :if={elem(exit, 0) == :click}
              phx-click={elem(exit, 2)}
              variant="outline"
              size="xs"
            >
              {elem(exit, 1)}
            </.button>
            <.button :if={elem(exit, 0) == :anchor} href={elem(exit, 2)} variant="outline" size="xs">
              {elem(exit, 1)}
            </.button>
          </li>
        </ul>
      </div>

      <.signed_return
        :if={@gstr3b_signoff}
        return="GSTR-3B"
        signoff={@gstr3b_signoff}
        month={@purchase_month}
        reopen_event="3b-reopen-signoff"
        reopen_id="gst-reopen-signoff"
        reopen_confirm="Reopen this signed month? The signature is revoked and the month can be worked again."
        filed_event="3b-mark-filed"
        form_id="gst-mark-filed"
        arn_id="gst-filed-arn"
        filed_note_id="gst-filed-note"
        can_sign_off={@can_sign_off}
      />
    </section>
    """
  end

  attr :gstr3b, :any, default: nil
  attr :stats, :any, default: nil
  attr :signed, :boolean, default: false

  def gstr3b_evidence(assigns) do
    ~H"""
    <section :if={show_gstr3b_evidence?(@gstr3b, @stats, @signed)} id="month-3b" class="space-y-block">
      <div>
        <p class="text-eyebrow text-moon font-semibold uppercase">Return evidence</p>
        <%!-- "Assembled" reads as finished. Until it is signed, this is what the
              return would say if the month closed now — and while bills are
              missing, part of it rests on documents nobody has. --%>
        <h2 class="text-base-content text-h4 font-semibold">
          {if @signed, do: "Assembled GSTR-3B", else: "GSTR-3B preview"}
        </h2>
      </div>
      <.gstr3b_panel gstr3b={@gstr3b} />
      <%!-- Net ITC comes off the 2B ceiling, which counts every 2B invoice
            including the ones whose bills were never supplied. Stating that
            beside the total stops a claim-ready figure standing alone. --%>
      <%!-- Snapshots frozen before this money existed have the count but not the
            rupees, and "₹0.00 across 5 invoices" contradicts itself. A signed
            month is immutable, so the note simply stays quiet there. --%>
      <p
        :if={(@stats && @stats.awaiting_bills > 0) and @stats.awaiting_bills_tax_paise > 0}
        id="gst-3b-unsupported"
        class="text-ink-muted text-ui"
      >
        {Nila.Formatters.format_money_with_paise(@stats.awaiting_bills_tax_paise)} of this credit
        has no supplied bill behind it, across {@stats.awaiting_bills} {if @stats.awaiting_bills ==
                                                                             1,
                                                                           do: "invoice",
                                                                           else: "invoices"} the portal reported. Collect the documents before claiming it.
      </p>
    </section>
    """
  end

  attr :return, :string, required: true
  attr :signoff, :any, required: true
  attr :month, :any, required: true
  attr :reopen_event, :string, required: true
  attr :reopen_id, :string, required: true
  attr :reopen_confirm, :string, required: true
  attr :filed_event, :string, required: true
  attr :form_id, :string, required: true
  attr :arn_id, :string, required: true
  attr :filed_note_id, :string, required: true
  attr :can_sign_off, :boolean, required: true
  slot :extra_step

  defp signed_return(assigns) do
    ~H"""
    <div class="space-y-block">
      <div class="flex flex-wrap items-center gap-2">
        <span class="text-base-content text-ui font-semibold">{@return}</span>
        <.badge variant={if @month.filed_at, do: "neutral", else: "success"}>
          {if @month.filed_at, do: "Filed", else: approval_label(@return)}
        </.badge>
      </div>

      <dl class="gap-block text-meta grid sm:grid-cols-4">
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
        <div :if={@return == "GSTR-1" and @signoff.snapshot["draft_version"]}>
          <dt class="text-ink-subtle text-label font-semibold uppercase">Draft version</dt>
          <dd class="text-base-content font-mono">
            {String.slice(@signoff.snapshot["draft_version"], 0, 12)}
          </dd>
        </div>
        <div :if={@month.filed_at} id={@filed_note_id}>
          <dt class="text-ink-subtle text-label font-semibold uppercase">Filed</dt>
          <dd class="text-base-content font-medium">{format_display_datetime(@month.filed_at)}</dd>
        </div>
        <div :if={@month.filing_arn}>
          <dt class="text-ink-subtle text-label font-semibold uppercase">ARN</dt>
          <dd class="text-base-content font-mono break-all">{@month.filing_arn}</dd>
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
        {if @return == "GSTR-1", do: "Reopen approval", else: "Reopen signature"}
      </.button>

      <div :if={is_nil(@month.filed_at)} class="gap-section grid items-start lg:grid-cols-3">
        {render_slot(@extra_step)}
        <div class="space-y-related">
          <p class="text-ink-subtle text-label font-semibold uppercase">GST portal</p>
          <a
            href="https://www.gst.gov.in/"
            target="_blank"
            rel="noopener"
            class="text-moon text-ui font-semibold"
          >
            Open gst.gov.in →
          </a>
        </div>
        <form id={@form_id} phx-submit={@filed_event} class="space-y-related">
          <.input
            type="text"
            name="arn"
            id={@arn_id}
            value=""
            label="Filing ARN"
            placeholder="Optional"
            class="input input-bordered w-full font-mono"
          />
          <.button type="submit" variant="outline" size="xs">Mark filed on portal</.button>
        </form>
      </div>
    </div>
    """
  end

  defp gstr1_actionable?(assigns) do
    not is_nil(assigns.r1_signoff) or assigns.reviewable
  end

  defp approval_label("GSTR-1"), do: "Approved"
  defp approval_label(_return), do: "Signed"

  # `data-confirm` guarded reopening a signature but not giving one, which had
  # the caution exactly backwards. Naming the money in the prompt also means the
  # figures are in front of the signer at the moment of signing even if they
  # never scrolled the summary.
  defp approval_confirm(nil), do: nil

  defp approval_confirm(filed) do
    "Approve the GSTR-1 filing #{Helpers.rupees(filed.taxable)} taxable and " <>
      "#{Helpers.rupees(filed.tax)} output tax?"
  end

  # The full server gate (`Signoffs.sign_off/2`), each condition paired with the
  # control that clears it. Uncollected bills and vendor amount disputes stay
  # visible as findings and in the money, but neither is answerable here, so
  # neither appears.
  #
  # All three server gates have to be mirrored, not the one that happened to be
  # cheap to check here: the two omitted both failed at the click, and one of
  # them — sales intake on a month with no sales side — had its only control
  # inside a section that does not render without a sales month.
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
       {:none, nil, nil}},
      {"attestation", assigns.stats.need_decision == 0 and attestation_open?(assigns.itc),
       "Nobody has confirmed whether the client holds tax invoices for the supplies the portal reported (s.16(2)(a)).",
       {:patch, "Answer it", purchase_review}},
      {"no-sales", is_nil(assigns.sales_month),
       "This client-month has no sales side. The 3B takes its outward liability from the GSTR-1, so the sales month has to be worked and filed first — including a month with no sales at all.",
       {:navigate, "Bring in sales bills",
        ~p"/gst/upload?client_id=#{client_id}&period=#{period}"}},
      {"r1-unsigned", not is_nil(assigns.sales_month) and is_nil(assigns.r1_signoff),
       "The GSTR-1 has not been approved yet.", {:anchor, "Go to the GSTR-1", "#month-sales"}},
      {"r1-unfiled",
       not is_nil(assigns.sales_month) and not is_nil(assigns.r1_signoff) and
         is_nil(assigns.sales_month.filed_at),
       "The GSTR-1 is approved but not yet marked filed on the portal.",
       {:anchor, "Mark it filed", "#month-exit-gstr1"}},
      {"intake", assigns.sales_completeness != :complete,
       "Sales collection is #{completeness_phrase(assigns.sales_completeness)} — the client has not confirmed we hold everything.",
       {:click, "Record client confirmation", "open-completeness-override"}}
    ]
    |> Enum.filter(fn {_key, active?, _message, _exit} -> active? end)
    |> Enum.map(fn {key, _active?, message, exit} -> {key, message, exit} end)
  end

  # Required and not yet answered. `documents_attested` alone cannot say this:
  # it is `nil` both when no supply needs attesting and when one does and nobody
  # has answered, so keying off `"unknown"` left the commonest blocked state —
  # a fresh month with a 2B-only supply — rendering the sign button over a gate
  # the server refuses.
  defp attestation_open?(%{"attestation_required" => true} = itc),
    do: itc["documents_attested"] not in ~w(held not_held)

  defp attestation_open?(_itc), do: false

  defp completeness_phrase(:open), do: "not confirmed"
  defp completeness_phrase(:client_no), do: "still open"
  defp completeness_phrase(:stale), do: "stale after later or unresolved intake"
  defp completeness_phrase(_status), do: "incomplete"

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"

  attr :gstr3b, :map, required: true

  defp gstr3b_panel(assigns) do
    ~H"""
    <div id="gst-3b-panel" class="border-base-300 rounded-box border">
      <div class="border-base-300 gap-block flex items-center justify-between border-b px-4 py-3">
        <div class="text-body text-ink-muted">
          {if liability_missing?(@gstr3b),
            do: "ITC side assembled. Outward liability needs the month's sales bills.",
            else: "Assembled from the worked sales month and the 2B reconciliation."}
        </div>
        <div :if={!liability_missing?(@gstr3b)} class="shrink-0 text-right">
          <div class="text-ink-subtle text-label font-semibold uppercase">Cash payable</div>
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
          <div class="text-ink-subtle text-label font-semibold uppercase">
            3.1 Outward liability
          </div>
          <.gstr3b_line label="(a) Taxable supplies" heads={@gstr3b["liability_31"]["a"]} />
          <.gstr3b_line label="(d) Reverse charge" heads={@gstr3b["liability_31"]["d"]} />
        </div>
        <div :if={liability_missing?(@gstr3b)} class="space-y-1.5">
          <div class="text-ink-subtle text-label font-semibold uppercase">
            3.1 Outward liability
          </div>
          <p class="text-body text-ink-muted">
            No worked sales month for this period yet. Upload the sales bills to derive the GSTR-1 and complete the return.
          </p>
          <.gstr3b_line label="(d) Reverse charge" heads={@gstr3b["liability_31"]["d"]} />
        </div>
        <div class="space-y-1.5">
          <div class="text-ink-subtle text-label font-semibold uppercase">4. Eligible ITC</div>
          <.gstr3b_line label="A(3) Reverse charge credit" heads={@gstr3b["itc"]["rcm_4a3"]} />
          <.gstr3b_line label="A(5) All other ITC" heads={@gstr3b["itc"]["all_other_itc_4a5"]} />
          <.gstr3b_line label="B Reversed (confirmed blocks)" heads={sum_4b(@gstr3b["itc"])} negative />
          <.gstr3b_line label="C Net ITC" heads={@gstr3b["itc"]["net_itc_4c"]} strong />
        </div>
      </div>

      <%!-- What this panel does not cover, said out loud. The engine builds
            3.1(a) and 3.1(d) and nothing else, and a reviewer reading four
            populated lines has no way to tell "nil-rated: none" from "nil-rated
            was never considered". Silence about a table reads as a zero in it.
            Building 3.1(b)/(c)/(e) and Table 5 needs data no client supplies
            today; saying so costs nothing and is honest. --%>
      <p id="gst-3b-scope" class="border-base-300 text-ink-subtle text-meta border-t px-4 py-3">
        This covers 3.1(a) taxable and 3.1(d) reverse-charge outward supplies only. Zero-rated,
        nil-rated, exempt and non-GST supplies (3.1 b/c/e) and Table 5 are not assembled here —
        if the month has any, they have to be added on the portal.
      </p>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :heads, :map, required: true
  attr :negative, :boolean, default: false
  attr :strong, :boolean, default: false

  defp gstr3b_line(assigns) do
    # Nothing is being taken away at zero, so neither the minus sign nor the
    # alarm colour is earned. Same rule as the ITC panel: the negative treatment
    # belongs to the amount, not to the row's role.
    assigns = assign(assigns, :withheld?, assigns.negative and heads_total(assigns.heads) > 0)

    ~H"""
    <div class="flex items-baseline justify-between gap-3">
      <span class={[
        "text-ui",
        (@strong && "text-ink font-medium") || "text-ink-muted"
      ]}>
        {@label}
      </span>
      <span class={[
        "text-ui font-mono",
        @withheld? && "text-error",
        !@withheld? && ((@strong && "text-ink font-semibold") || "text-ink-muted")
      ]}>
        {if @withheld?, do: "−"}{money_paise(heads_total(@heads))}
      </span>
    </div>
    """
  end

  defp show_gstr3b_evidence?(nil, _stats, _signed), do: false
  defp show_gstr3b_evidence?(_gstr3b, _stats, true), do: true

  defp show_gstr3b_evidence?(gstr3b, stats, false) do
    not liability_missing?(gstr3b) and stats.need_decision == 0
  end

  defp liability_missing?(gstr3b), do: gstr3b["liability_source"] == "missing"
  defp heads_total(heads), do: (heads["igst"] || 0) + (heads["cgst"] || 0) + (heads["sgst"] || 0)
  defp sum_4b(itc), do: ItcPosition.sum_heads([itc["reversed_4b1"], itc["reversed_4b2"]])
  defp money_paise(paise), do: Nila.Formatters.format_money_with_paise(paise || 0)
end
