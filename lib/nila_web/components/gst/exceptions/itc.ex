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
      %{lines: opening(stats) ++ lines(itc)}
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
  defp opening(%{unreported_by_vendor_known?: true} = stats) do
    gap = stats.total_tax_paise - stats.unreported_by_vendor_tax_paise

    # Only when the two really differ. On a month where every books bill is in
    # the 2B, "ITC in your books" and "Reported in GSTR-2B" are one number, and
    # printing it twice with a −₹0 between them is noise.
    if stats.unreported_by_vendor_tax_paise > 0 and gap >= 0 do
      [
        %{
          key: "books-itc",
          label: "ITC in your books",
          note: nil,
          paise: stats.total_tax_paise,
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
      ]
    else
      []
    end
  end

  defp opening(_stats), do: []

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
      deduction("blocked", "less blocked credits", itc["blocked_in_ceiling_paise"], nil) ++
      deduction(
        "pending",
        "less awaiting a decision",
        itc["pending_decision_paise"],
        "Nobody has ruled on these yet"
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

  @doc """
  The s.16(2)(a) question: does the client hold tax invoices for the supplies
  the portal reported and nobody has sent us?

  Asked rather than assumed. The credit is claimed by default because a bill
  that has not reached Nila says nothing about whether the client holds it — but
  claiming it silently is the one version of this that is indefensible, so the
  claim is not signable until somebody answers.
  """
  attr :attestation, :any, required: true
  attr :signed_off, :boolean, default: false

  def document_attestation(assigns) do
    ~H"""
    <div
      :if={@attestation}
      id="gst-itc-attestation"
      class={[
        "rounded-box space-y-related border p-4",
        (@attestation.answer in [nil, "unknown"] && "bg-warning/5 border-warning/40") ||
          "border-base-300"
      ]}
    >
      <p class="text-base-content text-ui">
        {@attestation.count} {pluralise(@attestation.count, "supply")} in the 2B {if @attestation.count ==
                                                                                       1,
                                                                                     do: "has",
                                                                                     else: "have"} no bill on file, carrying
        <span class="font-mono font-semibold">{itc_money(@attestation.tax_paise)}</span>
        of credit. Confirm the client holds tax invoices for {if @attestation.count == 1,
          do: "it",
          else: "them"} before the credit is claimed.
      </p>

      <div :if={is_nil(@attestation.answer) and not @signed_off} class="flex flex-wrap gap-2">
        <.button
          variant="primary"
          size="sm"
          id="gst-attest-held"
          phx-click="attest_documents"
          phx-value-answer="held"
        >
          Client holds them
        </.button>
        <.button
          variant="outline"
          size="sm"
          id="gst-attest-not-held"
          phx-click="attest_documents"
          phx-value-answer="not_held"
        >
          Not held — withhold {itc_money(@attestation.tax_paise)}
        </.button>
        <%!-- Never force a "no" to proceed: "I haven't checked" is the honest
              answer most of the time, and it routes to the client. --%>
        <.button
          variant="ghost"
          size="sm"
          id="gst-attest-unknown"
          phx-click="attest_documents"
          phx-value-answer="unknown"
        >
          Unknown — ask the client
        </.button>
      </div>

      <div :if={@attestation.answer} class="flex flex-wrap items-center gap-2">
        <span class={[
          "text-meta font-medium",
          (@attestation.answer == "unknown" && "text-warning") || "text-ink-subtle"
        ]}>
          {answer_note(@attestation)}
        </span>
        <.button
          :if={not @signed_off}
          variant="ghost"
          size="xs"
          id="gst-attest-undo"
          phx-click="reopen_attestation"
        >
          Undo
        </.button>
      </div>
    </div>
    """
  end

  defp answer_note(%{answer: "held"}),
    do: "Client holds the tax invoices — credit claimed."

  defp answer_note(%{answer: "not_held", tax_paise: paise}),
    do: "Not held — #{itc_money(paise)} withheld from the claim."

  defp answer_note(%{answer: "unknown"}),
    do:
      "Unanswered — the client has been asked. The month cannot be signed until this is settled."

  defp pluralise(1, "supply"), do: "supply"
  defp pluralise(_count, "supply"), do: "supplies"

  attr :itc, :map, required: true
  attr :signed_off, :boolean, required: true
  attr :stats, :any, default: nil

  def itc_panel(%{itc: %{"blocks" => []}} = assigns) do
    ~H"""
    <div id="gst-itc-panel" class="space-y-related">
      <.itc_bridge itc={@itc} stats={@stats} id="gst-itc-bridge" />
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
      <.itc_bridge itc={@itc} stats={@stats} id="gst-itc-bridge" />

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
                phx-value-block-id={b["block_id"]}
              >
                Block
              </.button>
              <.button
                variant="ghost"
                size="xs"
                phx-click="allow_itc"
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
                phx-value-block-id={b["block_id"]}
              >Undo</.button>
            </span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp itc_money(paise), do: Nila.Formatters.format_money_with_paise(paise || 0)

  defp withheld?(block), do: (block["tax_paise"] || 0) > 0
end
