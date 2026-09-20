defmodule NilaWeb.Components.Gst.Exceptions.Itc do
  use NilaWeb, :html

  @moduledoc "ITC presentation for the GST exception workbench."

  @doc """
  The month's ITC as arithmetic: the reviewed opening credit and how it was
  split into current claim, later, excluded and pending amounts.

  One component, rendered on both the month card and the workbench, because
  those two screens described the same money in different words — a reviewer
  moving between them had no way to tell whether the figures disagreed or the
  vocabulary did.

  Imported 2B tax is source context. It is not the opening balance, which can
  include credit carried from an earlier period.
  """
  attr :itc, :map, required: true
  attr :id, :string, default: "gst-itc-bridge"
  attr :class, :string, default: nil
  attr :stats, :any, default: nil

  def itc_bridge(assigns) do
    assigns = assign(assigns, :bridge, bridge_rows(assigns.itc))

    ~H"""
    <div
      :if={@bridge}
      id={@id}
      class={["border-rule w-full max-w-5xl border-y", @class]}
    >
      <dl class="divide-rule divide-y">
        <div
          :for={line <- @bridge.lines}
          id={"#{@id}-#{line.key}"}
          class={["py-related flex items-baseline justify-between gap-6", line.emphasis]}
        >
          <dt class="min-w-0">
            <span class={[
              "text-base-content text-ui",
              (line.total? or line[:subtotal?]) && "font-semibold"
            ]}>
              {line.label}
            </span>
            <span :if={line.note} class="text-ink-muted text-ui block">{line.note}</span>
          </dt>
          <dd class={[
            "text-base-content shrink-0 font-mono tabular-nums",
            (line.total? && "text-body font-semibold") ||
              (line[:subtotal?] && "text-ui font-semibold") || "text-ui"
          ]}>
            {line.sign}{itc_money(line.paise)}
          </dd>
        </div>
      </dl>
    </div>
    """
  end

  @doc "A qualification of the proposed amount, separate from the arithmetic that derives it."
  attr :itc, :map, required: true
  attr :stats, :any, default: nil
  attr :id, :string, default: "gst-itc-supporting-evidence"

  def supporting_evidence(assigns) do
    ~H"""
    <div
      :if={(@itc["awaiting_document_paise"] || 0) > 0}
      id={@id}
      class="gap-block nila-itc-awaiting-document flex flex-wrap items-start justify-between border-l-2 px-4 py-3"
    >
      <div class="min-w-0 space-y-0.5">
        <p class="text-base-content text-ui font-semibold">Supporting invoices pending</p>
        <p class="text-body text-ink-muted">
          {supporting_evidence_copy(@stats)}
        </p>
      </div>
      <p class="text-base-content text-body shrink-0 font-mono font-semibold tabular-nums">
        {itc_money(@itc["awaiting_document_paise"])}
      </p>
    </div>
    """
  end

  defp bridge_rows(%{"opening_outstanding_paise" => _} = itc), do: %{lines: lines(itc)}
  defp bridge_rows(_itc), do: nil

  defp lines(itc) do
    [
      %{
        key: "reported-context",
        label: "Reported in GSTR-2B this period",
        note:
          "Source amount for this period; carried credit is shown in the opening balance below.",
        paise: itc["reported_2b_paise"],
        sign: "",
        total?: false,
        emphasis: nil
      },
      %{
        key: "opening",
        label: "Opening outstanding ITC",
        note: "Includes eligible credit carried from earlier periods.",
        paise: itc["opening_outstanding_paise"],
        sign: "",
        total?: false,
        subtotal?: true,
        emphasis: "border-rule border-t-2"
      }
    ] ++
      deduction("later", "Less: claim later", itc["later_paise"], nil) ++
      deduction("excluded", "Less: excluded", itc["excluded_paise"], nil) ++
      deduction("pending", "Less: pending decision", itc["pending_paise"], nil) ++
      [
        %{
          key: "claimable",
          label: "Claim this period",
          note: nil,
          paise: itc["current_claim_paise"],
          sign: "",
          total?: true,
          emphasis: "border-rule border-t-2"
        }
      ]
  end

  defp deduction(_key, _label, paise, _note) when paise in [0, nil], do: []

  defp deduction(key, label, paise, note),
    do: [
      %{key: key, label: label, note: note, paise: paise, sign: "−", total?: false, emphasis: nil}
    ]

  defp supporting_evidence_copy(%{awaiting_bills: count}) when count > 0,
    do:
      "#{count} #{if count == 1, do: "supply appears", else: "supplies appear"} in GSTR-2B without an invoice on file. Check the recorded treatment before claiming."

  defp supporting_evidence_copy(_stats),
    do:
      "Supplies appear in GSTR-2B without invoices on file. Check the recorded treatment before claiming."

  attr :itc, :map, required: true
  attr :signed_off, :boolean, required: true
  attr :stats, :any, default: nil
  attr :show_bridge, :boolean, default: true
  attr :target, :any, default: nil

  def itc_panel(%{itc: %{"blocks" => []}} = assigns) do
    ~H"""
    <div id="gst-itc-panel" class="space-y-related">
      <.itc_bridge :if={@show_bridge} itc={@itc} stats={@stats} id="gst-itc-bridge" />
      <.supporting_evidence
        :if={@show_bridge}
        itc={@itc}
        stats={@stats}
        id="gst-itc-supporting-evidence"
      />
      <div
        :if={is_nil(@itc["reported_2b_paise"])}
        class="border-rule rounded-box flex items-center justify-between border px-4 py-3"
      >
        <span class="text-ink-muted text-ui">
          Current proposed ITC (2B ceiling, no blocked credits)
        </span>
        <span id="gst-itc-claimable" class="text-base-content text-body font-mono font-semibold">
          {itc_money(@itc["claimable_paise"])}
        </span>
      </div>
    </div>
    """
  end

  def itc_panel(assigns) do
    ~H"""
    <div id="gst-itc-panel" class="space-y-related">
      <%!-- The bridge states the arithmetic; the rows below are the decisions
            that move one of its terms. The old header asserted
            "2B ceiling − blocked", which was the whole story only when no
            money was pending or unsubstantiated. --%>
      <.itc_bridge :if={@show_bridge} itc={@itc} stats={@stats} id="gst-itc-bridge" />
      <.supporting_evidence
        :if={@show_bridge}
        itc={@itc}
        stats={@stats}
        id="gst-itc-supporting-evidence"
      />

      <div class="border-rule rounded-box border">
        <div
          :if={is_nil(@itc["reported_2b_paise"])}
          class="border-rule flex items-center justify-between border-b px-4 py-3"
        >
          <div class="text-ink-subtle text-label font-medium uppercase">Current proposed ITC</div>
          <div id="gst-itc-claimable" class="text-base-content text-lead font-mono font-semibold">
            {itc_money(@itc["claimable_paise"])}
          </div>
        </div>

        <div class="divide-rule divide-y">
          <div
            :for={b <- @itc["blocks"]}
            id={"itc-block-#{b["block_id"]}"}
            class="flex flex-wrap items-center gap-x-3 gap-y-1.5 px-4 py-3"
          >
            <span class="text-ink-subtle text-label w-40 shrink-0 uppercase">
              {issue_label(b["code"])}{if b["section"], do: " · #{b["section"]}"}
            </span>
            <span class="text-base-content text-ui min-w-0 flex-1 truncate">
              {b["vendor"]} · {b["invoice_number"] || "—"}
            </span>
            <%!-- Nothing is being taken away at zero, so neither the minus sign nor
                the alarm colour is earned. --%>
            <span class={[
              "text-ui w-24 text-right font-mono",
              ((b["state"] == "blocked" and withheld?(b)) && "nila-itc-value-blocked") ||
                "text-ink-subtle"
            ]}>
              {if withheld?(b), do: "−", else: ""}{itc_money(b["tax_paise"])}
            </span>
            <span :if={b["state"] == "recommended" and not @signed_off} class="flex gap-1.5">
              <.button
                variant="error"
                size="xs"
                phx-click="block_itc"
                phx-target={@target}
                phx-value-block-id={b["block_id"]}
              >
                Block
              </.button>
              <.button
                variant="ghost"
                size="xs"
                phx-click="allow_itc"
                phx-target={@target}
                phx-value-block-id={b["block_id"]}
              >
                Keep credit
              </.button>
            </span>
            <span :if={b["state"] == "blocked"} class="flex items-center gap-1.5">
              <span class="nila-itc-status-blocked text-ui font-medium">Blocked</span>
              <.button
                :if={not @signed_off}
                variant="ghost"
                size="xs"
                phx-click="reopen_block"
                phx-target={@target}
                phx-value-block-id={b["block_id"]}
              >Undo</.button>
            </span>
            <span :if={b["state"] == "allowed"} class="flex items-center gap-1.5">
              <span class="text-ink-subtle text-ui font-medium">Credit kept</span>
              <.button
                :if={not @signed_off}
                variant="ghost"
                size="xs"
                phx-click="reopen_block"
                phx-target={@target}
                phx-value-block-id={b["block_id"]}
              >Undo</.button>
            </span>
          </div>
        </div>

        <%!-- Otherwise these rows read as credit taken away, and the bridge
              above — which correctly ignores them — looks wrong instead. --%>
        <div
          :if={(@itc["blocked_outside_ceiling_paise"] || 0) > 0}
          id="gst-itc-blocked-outside-ceiling"
          class="border-rule text-body text-ink-subtle border-t px-4 py-3"
        >
          {itc_money(@itc["blocked_outside_ceiling_paise"])} of the above sits outside the 2B
          ceiling — the portal never reported that credit, so blocking it withholds nothing and
          the claim is unchanged.
        </div>
      </div>
    </div>
    """
  end

  defp itc_money(paise), do: Nila.Formatters.format_money_with_paise(paise || 0)

  # A block only withholds credit the claim actually contained. Blocking a
  # books-only bill the 2B never reported takes nothing away — `ItcPosition`
  # excludes it from `blocked_in_ceiling_paise` for exactly that reason — so
  # printing −₹180 in alarm red against it contradicted the bridge two inches
  # above, which was unchanged.
  defp withheld?(block), do: (block["tax_paise"] || 0) > 0 and block["in_ceiling"]
end
