defmodule NilaWeb.Components.Gst.Month.Filing do
  use NilaWeb, :html

  @moduledoc "Audited return actions rendered directly after their evidence."

  alias Nila.Gst.Filing.{Gstr3b, ItcPosition, TallyPrime, WinmanGstr1}
  alias Nila.Gst.Sales.Values
  alias NilaWeb.Components.Gst.Exceptions.Itc
  alias NilaWeb.Components.Gst.Month.Helpers

  attr :sales_month, :any, required: true
  attr :r1_signoff, :any, default: nil
  attr :open_issue_count, :integer, required: true
  attr :reviewable, :boolean, required: true
  attr :sales_intake_open, :boolean, default: false
  attr :can_sign_off, :boolean, required: true
  attr :derived, :any, default: nil
  attr :readiness, :map, required: true

  def gstr1_actions(assigns) do
    assigns =
      assigns
      |> assign(:filed, assigns.derived && Values.filed_totals(assigns.derived))
      |> assign(:tally_form, to_form(%{}, as: :tally))

    ~H"""
    <div id="gstr1-handoff" class="py-section space-y-related">
      <section
        id="month-exit-gstr1"
        class="border-base-300 pt-block scroll-mt-28 border-t"
      >
        <div
          :if={@readiness.state == :provisional}
          class="space-y-1"
        >
          <h3 class="text-base-content text-h4 font-semibold">Approval</h3>
          <p id="gstr1-approval-status" class="text-base-content text-body font-medium">
            {@readiness.action_copy}
          </p>
        </div>

        <div
          :if={@readiness.state in [:ready, :awaiting_senior]}
          class="gap-block flex flex-wrap items-center justify-between"
        >
          <div class="space-y-1">
            <h3 class="text-base-content text-h4 font-semibold">Approval</h3>
            <p id="gstr1-approval-status" class="text-base-content text-body font-medium">
              {@readiness.action_copy}
            </p>
            <p :if={@filed} id="month-exit-gstr1-amount" class="text-base-content text-ui">
              Filing <span class="font-mono font-semibold">{Helpers.rupees(@filed.taxable)}</span>
              taxable and <span class="font-mono font-semibold">{Helpers.rupees(@filed.tax)}</span>
              output tax.
            </p>
          </div>
          <.button
            :if={@readiness.state == :ready}
            id="month-door-sign-r1"
            variant="primary"
            size="sm"
            phx-click="r1-sign-off"
            data-confirm={approval_confirm(@filed)}
          >
            Approve GSTR-1
          </.button>
        </div>

        <.signed_return
          :if={@readiness.state in [:approved, :filed]}
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
                download
                variant="outline"
                size="xs"
              >
                Download GST JSON
              </.button>
            </div>
          </:extra_step>
        </.signed_return>
      </section>

      <section
        :if={WinmanGstr1.supported_period?(@sales_month.period)}
        id="gstr1-winman-b2b-export"
        class="gap-block flex flex-wrap items-center justify-between"
      >
        <div class="space-y-1">
          <p class="text-ink-subtle text-label font-semibold uppercase">Filing artifact</p>
          <p class="text-base-content text-ui font-medium">Winman import · B2B sheet</p>
          <p class="text-ink-subtle text-meta">Only the B2B sheet is populated in this version.</p>
        </div>
        <.button
          id="gstr1-download-winman-b2b"
          href={~p"/gstr1/#{@sales_month.client_id}/#{@sales_month.period}/winman-b2b.xlsm"}
          download
          variant="outline"
          size="xs"
        >
          Download Winman B2B
        </.button>
      </section>

      <section
        id="gstr1-tally-export"
        class="gap-block flex flex-wrap items-center justify-between"
      >
        <div class="space-y-1">
          <p class="text-ink-subtle text-label font-semibold uppercase">Accounting handoff</p>
          <p class="text-base-content text-ui font-medium">TallyPrime · GL sales vouchers</p>
          <p class="text-ink-subtle text-meta">
            Import the XML in TallyPrime. GST return metadata is not included in this version.
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
            Download Tally XML
          </.button>
          <.form
            :if={@can_sign_off and TallyPrime.available?()}
            for={@tally_form}
            id="gstr1-send-tally-form"
            action={~p"/gstr1/#{@sales_month.client_id}/#{@sales_month.period}/tally"}
            method="post"
          >
            <.button
              id="gstr1-send-tally"
              type="submit"
              variant="outline"
              size="xs"
              data-confirm="Send all active sales vouchers to the company currently open in TallyPrime?"
            >
              Send to TallyPrime
            </.button>
          </.form>
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

      not is_nil(assigns.r1_signoff) ->
        %{
          state: :approved,
          title: "Approved GSTR-1",
          status: "Approved draft frozen for portal filing",
          action_copy: nil
        }

      not assigns.reviewable or assigns.sales_intake_open ->
        provisional_readiness(assigns)

      assigns.can_sign_off ->
        %{
          state: :ready,
          title: "Proposed GSTR-1",
          status: "Ready for approval",
          action_copy: "Ready for approval"
        }

      true ->
        %{
          state: :awaiting_senior,
          title: "Proposed GSTR-1",
          status: "Draft checks complete — awaiting a senior",
          action_copy: "Ready · A senior must approve this return"
        }
    end
  end

  defp provisional_readiness(assigns) do
    required = assigns.open_issue_count
    intake? = assigns.sales_intake_open

    {status, action_copy} =
      cond do
        required > 0 and intake? ->
          {"Provisional — required work and an unresolved sales packet prevent approval",
           "Blocked · #{required} required #{if required == 1, do: "item", else: "items"} and a sales packet remain unresolved"}

        required > 0 ->
          item = if required == 1, do: "item", else: "items"

          {"Provisional — #{required} required #{item} #{if required == 1, do: "prevents", else: "prevent"} approval",
           "Blocked · #{required} required #{item} #{if required == 1, do: "remains", else: "remain"}"}

        intake? ->
          {"Provisional — an unresolved sales packet prevents approval",
           "Blocked · 1 sales packet remains unresolved"}

        true ->
          {"Provisional — approval checks are incomplete",
           "Blocked · approval checks are incomplete"}
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
  attr :stats, :any, required: true
  attr :gstr3b_signoff, :any, default: nil
  attr :r1_signoff, :any, default: nil
  attr :can_sign_off, :boolean, required: true
  attr :sales_intake_open, :boolean, default: false
  attr :itc, :any, default: nil
  attr :gstr3b, :any, default: nil

  def gstr3b_actions(assigns) do
    assigns = assign(assigns, :blockers, gstr3b_blockers(assigns))

    ~H"""
    <section
      :if={not is_nil(@gstr3b_signoff) or @blockers == [] or @purchase_month.state == "worked"}
      id="month-exit-gstr3b"
      class="border-base-300 pt-section scroll-mt-28 border-t"
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
          <.button
            :if={@blockers == [] and @can_sign_off}
            id="month-door-sign-3b"
            variant="primary"
            size="sm"
            phx-click="3b-sign-off"
          >
            Sign the GSTR-3B
          </.button>
        </div>

        <%!-- Three of these are server gates in `Signoffs.sign_off/2` — the
              register, the s.16(2)(a) attestation and the sales intake — and the
              button used to render on the register alone, so the other two failed
              at the click with a flash naming a control on a different page and no
              way to reach it. The remaining three are this page's own filing
              order: the 3B takes its outward liability from the GSTR-1, so it
              waits for one that is approved and filed. The server would accept a
              signature without them; the sequence is ours. --%>
        <ul
          :if={@blockers != []}
          id="month-exit-gstr3b-blocked"
          class="divide-base-300 divide-y"
        >
          <li
            :for={{key, message, exit} <- @blockers}
            id={"gstr3b-blocker-#{key}"}
            class="gap-block py-related flex flex-wrap items-center justify-between"
          >
            <span class="text-ink-muted text-ui min-w-0 flex-1">{message}</span>
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
  attr :itc, :any, default: nil
  attr :stats, :any, default: nil
  attr :signed, :boolean, default: false

  def gstr3b_evidence(assigns) do
    ~H"""
    <section :if={show_gstr3b_evidence?(@gstr3b, @stats, @signed)} id="month-3b" class="space-y-block">
      <div class="space-y-1">
        <h3 class="text-base-content text-h4 font-semibold">
          {if @signed, do: "Signed GSTR-3B", else: "Proposed GSTR-3B"}
        </h3>
        <p :if={not @signed} id="gstr3b-preview-status" class="text-body text-ink-muted">
          {gstr3b_preview_status(@gstr3b, @stats)}
        </p>
      </div>

      <div class="space-y-related">
        <dl
          id="gst-3b-position"
          class="border-base-300 gap-block py-block grid border-y sm:grid-cols-3"
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
              :if={cash_available?(@gstr3b, @stats, @signed)}
              id="gst-3b-cash"
              class="text-base-content text-lead font-semibold tabular-nums"
            >
              {money_paise(@gstr3b["setoff_61"]["cash_total"])}
            </dd>
            <dd
              :if={not cash_available?(@gstr3b, @stats, @signed)}
              id="gst-3b-cash-pending"
              class="text-ink-muted text-ui font-medium"
            >
              {cash_pending_copy(@gstr3b)}
            </dd>
          </div>
        </dl>

        <Itc.supporting_evidence
          :if={not @signed and @itc}
          itc={@itc}
          stats={@stats}
          id="gstr3b-itc-supporting-evidence"
        />
      </div>

      <.data_table
        :if={filing_detail_ready?(@gstr3b, @stats, @signed)}
        id="gst-3b-filing-detail"
        rows={gstr3b_rows(@gstr3b)}
        row_id={&"gst-3b-row-#{&1.key}"}
        min_width="min-w-[640px]"
        dense
      >
        <:col :let={row} label="GSTR-3B section">
          <span class={row.strong? && "text-base-content font-semibold"}>{row.label}</span>
        </:col>
        <:col :let={row} label="IGST" align="right">
          {head_money(row, "igst")}
        </:col>
        <:col :let={row} label="CGST" align="right">
          {head_money(row, "cgst")}
        </:col>
        <:col :let={row} label="SGST" align="right">
          {head_money(row, "sgst")}
        </:col>
        <:col :let={row} label="Total" align="right">
          <span class={row.strong? && "text-base-content font-semibold"}>{row_total(row)}</span>
        </:col>
      </.data_table>
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
      {"attestation", assigns.stats.need_decision == 0 and attestation_open?(assigns.itc),
       "Nobody has confirmed whether the client holds tax invoices for the supplies the portal reported (s.16(2)(a)).",
       {:patch, "Answer it", purchase_review}},
      {"no-sales", is_nil(assigns.sales_month),
       "GSTR-1 is not ready, so outward liability and cash payable are still pending.",
       {:navigate, "Bring in sales bills",
        ~p"/gst/upload?client_id=#{client_id}&period=#{period}"}},
      {"r1-unsigned", not is_nil(assigns.sales_month) and is_nil(assigns.r1_signoff),
       "The GSTR-1 has not been approved yet.", {:anchor, "Go to the GSTR-1", "#month-sales"}},
      {"r1-unfiled",
       not is_nil(assigns.sales_month) and not is_nil(assigns.r1_signoff) and
         is_nil(assigns.sales_month.filed_at),
       "The GSTR-1 is approved but not yet marked filed on the portal.",
       {:anchor, "Mark it filed", "#month-exit-gstr1"}},
      {"sales-intake", assigns.sales_intake_open,
       "A supplied sales packet is still unresolved, so the outward liability may be incomplete.",
       {:anchor, "Review the packet", "#month-sales-sources"}},
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
  defp attestation_open?(%{"attestation_required" => true} = itc),
    do: itc["documents_attested"] not in ~w(held not_held per_case)

  defp attestation_open?(_itc), do: false

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"

  defp current_proposed_itc(gstr3b, itc, signed?) do
    cond do
      signed? -> heads_total(gstr3b["itc"]["net_itc_4c"])
      is_map(itc) and is_number(itc["claimable_paise"]) -> itc["claimable_paise"]
      true -> heads_total(gstr3b["itc"]["net_itc_4c"])
    end
  end

  defp cash_available?(gstr3b, stats, signed?) do
    not liability_missing?(gstr3b) and
      (signed? or is_nil(stats) or stats.need_decision == 0)
  end

  defp cash_pending_copy(gstr3b) do
    if liability_missing?(gstr3b), do: "Pending outward tax", else: "Pending decisions"
  end

  defp filing_detail_ready?(gstr3b, stats, signed?) do
    not liability_missing?(gstr3b) and
      (signed? or is_nil(stats) or stats.need_decision == 0)
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
