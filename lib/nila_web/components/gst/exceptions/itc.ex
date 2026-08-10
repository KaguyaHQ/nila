defmodule NilaWeb.Components.Gst.Exceptions.Itc do
  use NilaWeb, :html

  @moduledoc "ITC presentation for the GST exception workbench."

  @doc """
  The month's ITC as arithmetic: what the portal reported, what each state took
  out of it, and what is left to claim.

  One component, rendered on both the month card and the workbench, because
  those two screens described the same money in different words — a reviewer
  moving between them had no way to tell whether the figures disagreed or the
  vocabulary did.

  Every line is a term of `ItcPosition.partition/3`, which is tested to close.
  Substantiation sits *inside* the claim rather than beside it: a bill that has
  not reached Nila says nothing about whether the client holds it, so the money
  stays claimed, named, and attestable.
  """
  attr :itc, :map, required: true
  attr :id, :string, default: "gst-itc-bridge"
  attr :class, :string, default: nil
  attr :stats, :any, default: nil

  def itc_bridge(assigns) do
    assigns = assign(assigns, :bridge, bridge_rows(assigns.itc, assigns.stats))

    ~H"""
    <div :if={@bridge} id={@id} class={["border-base-300 rounded-box border", @class]}>
      <dl class="divide-base-300 divide-y">
        <div
          :for={line <- @bridge.lines}
          id={"#{@id}-#{line.key}"}
          class={["flex items-baseline justify-between gap-3 px-4 py-3", line.emphasis]}
        >
          <dt class="min-w-0">
            <span class={["text-ui", (line.total? && "font-semibold") || "text-ink-muted"]}>
              {line.label}
            </span>
            <span :if={line.note} class="text-ink-subtle text-meta block">{line.note}</span>
          </dt>
          <dd class={[
            "shrink-0 font-mono tabular-nums",
            (line.total? && "text-base-content text-body font-semibold") || "text-ink-muted text-ui"
          ]}>
            {line.sign}{itc_money(line.paise)}
          </dd>
        </div>
      </dl>
    </div>
    """
  end

  # `nil` for a snapshot frozen before the partition existed. Those months hold
  # a ceiling and a claimable figure but none of the terms between them, and
  # inventing zeroes would draw a bridge whose middle is a guess.
  defp bridge_rows(itc, stats) when is_map(itc) do
    if Map.has_key?(itc, "reported_2b_paise") do
      %{lines: opening(stats, itc) ++ lines(itc)}
    end
  end

  defp bridge_rows(_itc, _stats), do: nil

  # The month's own ITC, and the credit the portal has never reported, above the
  # 2B ceiling the rest of the bridge works from.
  #
  # Without these two lines the card said "ITC this month" and the bridge said
  # "Reported in GSTR-2B", the figures differed, and nothing explained why: a
  # reader had to subtract two totals to discover the gap. It is the sharpest
  # number on the page — credit the client cannot take this month because a
  # vendor has not filed — so it is stated rather than left to be derived.
  defp opening(%{unreported_by_vendor_known?: true} = stats, itc) do
    net_effect = Map.get(stats, :net_itc_effect_paise, stats.total_tax_paise)
    gap = net_effect - stats.unreported_by_vendor_tax_paise

    # Only when the two really differ. On a month where every books bill is in
    # the 2B, "ITC in your books" and "Reported in GSTR-2B" are one number, and
    # printing it twice with a −₹0 between them is noise.
    if stats.unreported_by_vendor_tax_paise > 0 and gap >= 0 do
      [
        %{
          key: "books-itc",
          label: "Net ITC effect in the register",
          note: nil,
          paise: net_effect,
          sign: "",
          total?: false,
          emphasis: nil
        },
        %{
          key: "not-in-2b",
          label: "less credit no vendor has reported",
          note: "Not claimable this month — the vendor has not filed it. Chase them.",
          paise: stats.unreported_by_vendor_tax_paise,
          sign: "−",
          total?: false,
          emphasis: nil
        }
      ] ++ basis_residual(gap, itc)
    else
      []
    end
  end

  defp opening(_stats, _itc), do: []

  # The two opening lines are books figures; every line below them is the 2B's.
  # Where the two disagree on the same supply the subtraction does not land on
  # the ceiling, and the bridge printed A − B above a C that was not A − B.
  #
  # Two things make it up: a value mismatch files the 2B's figure rather than
  # the books', and a supply still under review is counted at the 2B's. Naming
  # the residual is the honest fix — the alternative was a bridge whose first
  # arithmetic step silently did not hold.
  defp basis_residual(gap, itc) do
    case (itc["reported_2b_paise"] || 0) - gap do
      0 ->
        []

      residual ->
        [
          %{
            key: "basis-residual",
            label: "the 2B's figure where it differs from your books",
            note:
              "Value mismatches and supplies under review use the 2B's figure; supplier credit notes are shown separately as reversals.",
            paise: abs(residual),
            sign: (residual > 0 && "+") || "−",
            total?: false,
            emphasis: nil
          }
        ]
    end
  end

  defp lines(itc) do
    [
      %{
        key: "reported",
        label: "Reported in GSTR-2B",
        note: nil,
        paise: itc["reported_2b_paise"],
        sign: "",
        total?: false,
        emphasis: nil
      }
    ] ++
      deduction(
        "credit-notes",
        "less supplier credit notes",
        itc["credit_note_reversal_applied_paise"],
        "Positive face values; reversed in GSTR-3B Table 4B(2)."
      ) ++
      deduction("blocked", "less blocked credits", itc["blocked_in_ceiling_paise"], nil) ++
      deduction(
        "pending",
        "less awaiting a decision",
        itc["pending_decision_paise"],
        "Nobody has ruled on these yet"
      ) ++
      deduction(
        "withheld",
        "less credit the client holds no bill for",
        itc["unsubstantiated_withheld_paise"],
        "Attested under s.16(2)(a). Reversed in 4B(2) on the return."
      ) ++
      [
        %{
          key: "claimable",
          label: "Claimable ITC",
          note: nil,
          paise: itc["claimable_paise"],
          sign: "",
          total?: true,
          emphasis: "bg-base-200/40"
        }
      ] ++ substantiation(itc)
  end

  defp deduction(_key, _label, paise, _note) when paise in [0, nil], do: []

  defp deduction(key, label, paise, note),
    do: [
      %{key: key, label: label, note: note, paise: paise, sign: "−", total?: false, emphasis: nil}
    ]

  # The claim's own split. Silent when every rupee is substantiated, because
  # then there is nothing a reviewer needs to attest to.
  defp substantiation(%{"awaiting_document_paise" => awaiting}) when awaiting in [0, nil], do: []

  defp substantiation(itc) do
    [
      %{
        key: "awaiting-document",
        label: "of which the client hasn't sent us the bill",
        note: "Claimed on the 2B. Confirm the client holds the tax invoices.",
        paise: itc["awaiting_document_paise"],
        sign: "",
        total?: false,
        emphasis: nil
      }
    ]
  end

  attr :itc, :map, required: true
  attr :signed_off, :boolean, required: true
  attr :stats, :any, default: nil
  attr :show_bridge, :boolean, default: true
  attr :target, :any, default: nil

  def itc_panel(%{itc: %{"blocks" => []}} = assigns) do
    ~H"""
    <div id="gst-itc-panel" class="space-y-related">
      <.itc_bridge :if={@show_bridge} itc={@itc} stats={@stats} id="gst-itc-bridge" />
      <div
        :if={is_nil(@itc["reported_2b_paise"])}
        class="border-base-300 rounded-box flex items-center justify-between border px-4 py-3"
      >
        <span class="text-ink-muted text-ui">Claimable ITC (2B ceiling, no blocked credits)</span>
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

      <div class="border-base-300 rounded-box border">
        <div
          :if={is_nil(@itc["reported_2b_paise"])}
          class="border-base-300 flex items-center justify-between border-b px-4 py-3"
        >
          <div class="text-ink-subtle text-label font-medium uppercase">Claimable ITC</div>
          <div id="gst-itc-claimable" class="text-base-content text-lead font-mono font-semibold">
            {itc_money(@itc["claimable_paise"])}
          </div>
        </div>

        <div class="divide-base-300 divide-y">
          <div
            :for={b <- @itc["blocks"]}
            id={"itc-block-#{b["block_id"]}"}
            class="flex flex-wrap items-center gap-x-3 gap-y-1.5 px-4 py-3"
          >
            <span class="text-ink-subtle text-meta w-40 shrink-0 uppercase">
              {issue_label(b["code"])}{if b["section"], do: " · #{b["section"]}"}
            </span>
            <span class="text-base-content text-ui min-w-0 flex-1 truncate">
              {b["vendor"]} · {b["invoice_number"] || "—"}
            </span>
            <%!-- Nothing is being taken away at zero, so neither the minus sign nor
                the alarm colour is earned. --%>
            <span class={[
              "text-ui w-24 text-right font-mono",
              ((b["state"] == "blocked" and withheld?(b)) && "text-error") || "text-ink-subtle"
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
              <span class="text-error text-meta font-medium">Blocked</span>
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
              <span class="text-ink-subtle text-meta font-medium">Credit kept</span>
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
          class="border-base-300 text-ink-subtle text-meta border-t px-4 py-3"
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
