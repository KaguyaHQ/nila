defmodule NilaWeb.Components.Gst.Exceptions.Surface do
  use NilaWeb, :html

  @moduledoc "Queue, detail, and candidate presentation for the GST exception workbench."

  attr :queue, :list, required: true
  attr :groups, :list, required: true
  attr :selected_id, :any, default: nil
  attr :selected, :any, default: nil
  attr :signed_off, :boolean, required: true
  attr :correcting, :any, default: nil
  attr :evidence_page, :integer, default: 0
  attr :target, :any, default: nil

  def exception_surface(assigns) do
    ~H"""
    <div
      :if={@queue == []}
      id="gst-exceptions-empty"
      class="border-rule rounded-box border border-dashed px-4 py-12 text-center"
    >
      <.icon name="hero-check-circle" class="text-success mx-auto size-10" />
      <p class="mt-related text-base-content text-body font-medium">No exceptions</p>
      <p class="text-ink-muted text-ui mt-1">
        The engine matched every purchase document confidently — nothing needs a human decision.
      </p>
    </div>

    <div :if={@queue != []} class="grid h-full min-h-0 gap-4 lg:grid-cols-[20rem_1fr]">
      <div id="gst-exception-queue" class="space-y-block min-h-0 overflow-y-auto pr-1">
        <%!-- Each kind of work carries its own count and its own money, because
              a reviewer's decisions and a client's missing bills are not one
              backlog with one number. --%>
        <div
          :for={group <- @groups}
          id={"gst-exception-group-#{group.key}"}
          class="border-rule rounded-box border"
        >
          <div class="border-rule space-y-1 border-b px-3 py-2">
            <div class="flex items-baseline justify-between gap-2">
              <span class="text-base-content text-ui font-semibold">{group.title}</span>
              <span class="text-ink-muted text-ui font-mono whitespace-nowrap tabular-nums">
                {group.count} · {format_money(group.tax_paise, prefix: "₹")}
              </span>
            </div>
            <p class="text-ink-subtle text-ui">{group.blurb}</p>
            <%!-- Nila's position on the group, where it has one. A collection
                  queue's treatment is a request, not a decision, so it belongs
                  on the group rather than on each row. --%>
            <p :if={group[:proposal]} class="text-base-content text-ui font-medium">
              {group.proposal.action}
            </p>
          </div>
          <div class="divide-rule divide-y">
            <button
              :for={item <- group.items}
              type="button"
              id={"queue-#{item.id}"}
              phx-click="select"
              phx-target={@target}
              phx-value-id={item.id}
              class={[
                "flex w-full items-start gap-2 px-3 py-2 text-left transition",
                item.id == @selected_id && "bg-quiet",
                item.id != @selected_id && "hover:bg-interactive"
              ]}
            >
              <.icon
                :if={item.resolved}
                name="hero-check-circle-mini"
                class="text-success mt-0.5 size-4 shrink-0"
              />
              <span :if={not item.resolved} class="bg-warning mt-1.5 size-2 shrink-0 rounded-full" />
              <span class="flex min-w-0 flex-1 flex-col gap-1">
                <span class="flex items-baseline gap-2">
                  <span
                    class={[
                      "text-ui min-w-0 flex-1 truncate font-medium",
                      item.resolved && "text-ink-subtle",
                      not item.resolved && "text-base-content"
                    ]}
                    title={item.vendor}
                  >
                    {item.vendor}
                  </span>
                  <span
                    :if={item.tax_paise > 0}
                    id={"queue-tax-#{item.id}"}
                    class={[
                      "text-ui shrink-0 font-mono whitespace-nowrap tabular-nums",
                      (item.resolved && "text-ink-subtle") || "text-ink-muted"
                    ]}
                  >
                    {format_money(item.tax_paise, prefix: "₹")}
                  </span>
                </span>
                <% detail =
                  if item.resolved,
                    do: item.outcome,
                    else:
                      "#{document_label(item)} #{item.invoice_number || "without number"} · #{short_type(item.type)}" %>
                <span class="text-ink-subtle text-ui truncate" title={detail}>
                  {detail}
                </span>
              </span>
            </button>
          </div>
        </div>
      </div>

      <div
        id="gst-exception-detail"
        class="border-rule rounded-box min-h-0 overflow-y-auto border p-6"
      >
        <.detail
          selected={@selected}
          signed_off={@signed_off}
          correcting={@correcting}
          evidence_page={@evidence_page}
          target={@target}
        />
      </div>
    </div>
    """
  end

  attr :selected, :any, default: nil
  attr :signed_off, :boolean, required: true
  attr :correcting, :any, default: nil
  attr :evidence_page, :integer, default: 0
  attr :target, :any, default: nil

  def detail(%{selected: nil} = assigns) do
    ~H"""
    <p class="text-ink-muted text-ui">Select an exception from the queue.</p>
    """
  end

  def detail(%{selected: %{kind: :itc}} = assigns) do
    ~H"""
    <div id="gst-itc-decision" class="space-y-section">
      <div>
        <div class="flex flex-wrap items-center gap-2">
          <.badge variant="warning">{issue_label(@selected.type)}</.badge>
          <span :if={@selected.itc_block["section"]} class="text-ink-subtle text-ui">
            {@selected.itc_block["section"]}
          </span>
        </div>
        <h3 class="mt-related text-base-content text-body font-semibold">
          {@selected.invoice_number || "—"} · {@selected.vendor}
        </h3>
        <p class="text-ink-muted text-ui mt-1">{@selected.reason}</p>
      </div>

      <dl class="border-rule divide-rule rounded-box divide-y border">
        <div class="flex items-center justify-between gap-3 px-4 py-3">
          <dt class="text-ink-muted text-ui">Credit at stake</dt>
          <dd class="text-base-content text-ui font-mono whitespace-nowrap tabular-nums">
            {format_money(@selected.tax_paise, prefix: "₹")}
          </dd>
        </div>
        <div class="flex items-center justify-between gap-3 px-4 py-3">
          <dt class="text-ink-muted text-ui">Nila's conclusion</dt>
          <dd class="text-base-content text-ui font-medium">Block this credit</dd>
        </div>
      </dl>

      <div
        :if={not @selected.resolved and not @signed_off}
        class="border-rule pt-block flex flex-wrap gap-2 border-t"
      >
        <.button
          id="gst-itc-block"
          variant="error"
          size="sm"
          phx-click="block_itc"
          phx-target={@target}
          phx-value-block-id={@selected.itc_block["block_id"]}
        >Block credit</.button>
        <.button
          id="gst-itc-allow"
          variant="outline"
          size="sm"
          phx-click="allow_itc"
          phx-target={@target}
          phx-value-block-id={@selected.itc_block["block_id"]}
        >Keep credit</.button>
      </div>

      <div :if={@selected.resolved} class="border-rule pt-block flex items-center gap-3 border-t">
        <span class="nila-exception-outcome text-ui font-medium">{@selected.outcome}</span>
        <.button
          :if={not @signed_off}
          variant="ghost"
          size="sm"
          phx-click="reopen_block"
          phx-target={@target}
          phx-value-block-id={@selected.itc_block["block_id"]}
        >Undo</.button>
      </div>
    </div>
    """
  end

  def detail(assigns) do
    ~H"""
    <div class="space-y-section">
      <div>
        <h3 class="text-base-content text-body flex min-w-0 flex-wrap items-baseline gap-x-3 font-semibold">
          <span class="min-w-0 wrap-break-word">
            {document_label(@selected)} {@selected.invoice_number || "—"} · {@selected.vendor}
          </span>
          <span
            :if={@selected.tax_paise > 0}
            id="gst-exception-tax"
            class="text-ui font-mono whitespace-nowrap tabular-nums"
          >
            <%= if @selected.document_type == "credit_note" do %>
              {format_money(@selected.tax_paise, prefix: "₹")} face tax · −{format_money(
                @selected.tax_paise,
                prefix: "₹"
              )} ITC
            <% else %>
              {format_money(@selected.tax_paise, prefix: "₹")} tax at stake
            <% end %>
          </span>
        </h3>
        <p class="text-ink-muted text-ui mt-1">{@selected.reason}</p>
        <div :if={asked_label(@selected.asked_at)} class="mt-1">
          <.context_text tag="p" tone="moon" weight="medium">
            {asked_label(@selected.asked_at)}
          </.context_text>
        </div>
        <div
          :if={length(@selected.books_members) > 1}
          id="gst-exception-books-members"
          class="border-rule rounded-box mt-3 divide-y border"
        >
          <div
            :for={books <- @selected.books_members}
            id={"gst-exception-books-member-#{books["id"]}"}
            class="flex items-baseline justify-between gap-3 px-3 py-2"
          >
            <span class="text-base-content text-ui min-w-0 font-medium wrap-break-word">
              {books["vendor_name"]}
            </span>
            <span class="text-ink-muted text-ui font-mono wrap-break-word">
              {books["invoice_number"] || "—"}
            </span>
          </div>
        </div>
      </div>

      <%!-- The dispute is the hero: books-vs-2B leads, and the bill sits beside
      it as corroboration. A full-width A4 raster above the grid would push the
      ✓/✗ column below the fold and make the reviewer scroll between the two
      things they are comparing. --%>
      <div class={[
        "gap-block grid",
        (facts?(@selected) and evidence?(@selected)) && "lg:grid-cols-[1fr_15rem]"
      ]}>
        <div :if={facts?(@selected)} class="min-w-0 space-y-3">
          <div :if={@selected.candidates != []} id="gst-exception-candidates" class="space-y-3">
            <.candidate_card
              :for={{candidate, index} <- Enum.with_index(@selected.candidates, 1)}
              candidate={candidate}
              books={candidate.books}
              index={index}
              selected_id={candidate.books_id}
              show_pick={
                @selected.action == :ambiguous and not @selected.resolved and not @signed_off
              }
              target={@target}
            />
          </div>

          <.gstr2b_card :if={@selected.kind == :gstr2b} gstr2b={@selected.gstr2b} />
        </div>

        <%!-- Nothing to compare against (a bill the portal has never seen): the
        bill is the whole of the evidence, so it gets a column of its own rather
        than a lane beside an empty one. --%>
        <div
          :if={@selected.images != []}
          id="gst-exception-evidence"
          class={[not facts?(@selected) && "max-w-xs"]}
        >
          <.evidence_frame
            id="gst-exception-evidence-frame"
            images={@selected.images}
            page={@evidence_page}
            on_open="open-evidence"
            on_page="evidence-page"
            target={@target}
          />
        </div>

        <%!-- Absence exceptions (the bill was never received) render nothing
        here — the 2B card is the evidence, and absence is the information. A
        bill that arrived but could not be rasterized is a different case, and
        the only one with a next step. --%>
        <.evidence_unavailable
          :if={@selected.images == [] and @selected.evidence_gap}
          id="gst-exception-evidence-unavailable"
          source={@selected.evidence_gap.source}
          original_url={@selected.evidence_gap.original_url}
        />
      </div>

      <div
        :if={@selected.resolved}
        id="gst-exception-outcome"
        class="border-rule pt-block flex flex-wrap items-center gap-3 border-t"
      >
        <span class="nila-exception-outcome text-ui flex items-center gap-1.5 font-medium">
          <.icon name="hero-check-circle-mini" class="size-4" /> {@selected.outcome}
        </span>
        <.button
          :if={not @signed_off}
          variant="ghost"
          size="sm"
          phx-click="undo"
          phx-target={@target}
          phx-value-id={@selected.id}
        >
          <.icon name="hero-arrow-uturn-left-mini" class="size-4" /> Undo
        </.button>
        <.button
          :if={@selected.candidates != []}
          id="gst-challenge-match"
          variant="outline"
          size="sm"
          phx-click="challenge"
          phx-target={@target}
          phx-value-id={@selected.id}
          disabled={@signed_off}
          title={@signed_off && "Unlock the signed month first; filed returns require an amendment."}
        >Challenge this match</.button>
      </div>

      <div
        :if={@selected.action == :ambiguous and not @selected.resolved and not @signed_off}
        class="border-rule pt-block flex border-t"
      >
        <.button
          id="gst-reject-all-candidates"
          variant="outline"
          size="sm"
          phx-click="reject_all"
          phx-target={@target}
          phx-value-id={@selected.id}
        >None of these</.button>
      </div>

      <div
        :if={
          @selected.kind == :books and @selected.action in [:pair, :unmatched] and
            not @selected.resolved and not @signed_off
        }
        class="border-rule pt-block flex flex-wrap gap-2 border-t"
      >
        <%= if @correcting && @correcting.id in @selected.member_ids do %>
          <.correction_form selected={@selected} target={@target} />
        <% else %>
          <.button
            :if={@selected.action == :pair}
            variant="success"
            size="sm"
            phx-click="confirm_pair"
            phx-target={@target}
            phx-value-id={@selected.id}
          >Confirm — same bill</.button>
          <.button
            :if={@selected.action == :pair}
            variant="outline"
            size="sm"
            phx-click="reject_pair"
            phx-target={@target}
            phx-value-id={@selected.id}
          >Reject — not the same</.button>
          <%!-- Two buttons that move the same zero rupees read as a trick
                question, and the reviewer picks one at random. Keeping both is
                still right: a books bill with no 2B entry was never inside the
                ceiling, so neither can change this month's claim, and the whole
                difference is what happens next — one bill is coming back when
                the vendor files, the other is closed. That difference is real
                (it is what the register prints as the row's next action, and
                what a later month reads to pick the bill up again), so the fix
                is to say it at the click rather than to merge the two. --%>
          <p
            :if={@selected.action == :unmatched}
            id="gst-accept-unmatched-note"
            class="text-body text-ink-subtle basis-full"
          >
            <%= if @selected.document_type == "credit_note" do %>
              This supplier credit note already reduces ITC by {format_money(
                @selected.tax_paise,
                prefix: "₹"
              )}. The decision records whether its 2B filing is still expected.
            <% else %>
              Neither changes this month's claim — a bill with no 2B entry was never in the
              ceiling. They differ in what the register then says to do with it.
            <% end %>
          </p>
          <.button
            :if={@selected.action == :unmatched}
            id="gst-accept-await-2b"
            variant="outline"
            size="sm"
            phx-click="accept_unmatched"
            phx-target={@target}
            phx-value-id={@selected.id}
            phx-value-reason="await_2b"
          >{if @selected.document_type == "credit_note",
            do: "Supplier hasn't filed it yet · reversal retained",
            else: "Vendor hasn't filed it yet · claim in a later month"}</.button>
          <.button
            :if={@selected.action == :unmatched}
            id="gst-accept-not-claimable"
            variant="outline"
            size="sm"
            phx-click="accept_unmatched"
            phx-target={@target}
            phx-value-id={@selected.id}
            phx-value-reason="not_claimable"
          >{if @selected.document_type == "credit_note",
            do: "Close the note · reversal retained",
            else: "Not claimable · close the bill"}</.button>
          <.button
            variant="ghost"
            size="sm"
            phx-click="start_correct"
            phx-target={@target}
            phx-value-id={@selected.id}
          >
            Correct the number
          </.button>
        <% end %>
      </div>

      <div
        :if={@selected.action == :gstr2b and not @selected.resolved and not @signed_off}
        class="border-rule pt-block flex flex-wrap gap-2 border-t"
      >
        <.button
          id="gst-ask-client"
          variant="primary"
          size="sm"
          phx-click="open-ask"
          phx-target={@target}
          phx-value-id={@selected.id}
        >Ask the client for the {document_noun(@selected)}</.button>
        <.button
          id="gst-document-held"
          variant="outline"
          size="sm"
          phx-click="document_state"
          phx-target={@target}
          phx-value-id={@selected.id}
          phx-value-state="held"
        >{if @selected.document_type == "credit_note",
          do: "Client holds the credit note · reversal retained",
          else: "Client holds the bill · claim now"}</.button>
        <.button
          id="gst-document-defer"
          variant="outline"
          size="sm"
          phx-click="document_state"
          phx-target={@target}
          phx-value-id={@selected.id}
          phx-value-state="not_held"
        >{if @selected.document_type == "credit_note",
          do: "Credit note unavailable · reversal retained",
          else: "Withhold this month · carry forward"}</.button>
        <%!-- Dismissing removes the entry from `in_2b_not_books`, which drops
              the 2B ceiling and therefore the claim by this row's whole tax.
              It was the quietest click on the purchase side and the only one
              that silently shrinks the claim, so it names its own cost. --%>
        <.button
          id="gst-dismiss-2b"
          variant="outline"
          size="sm"
          phx-click="dismiss_2b"
          phx-target={@target}
          phx-value-id={@selected.id}
          data-confirm={dismiss_confirm(@selected)}
        >
          Not ours / ignore{dismiss_effect(@selected)}
        </.button>
      </div>
    </div>
    """
  end

  attr :candidate, :map, required: true
  attr :books, :map, required: true
  attr :index, :integer, required: true
  attr :selected_id, :string, required: true
  attr :show_pick, :boolean, required: true
  attr :target, :any, default: nil

  def candidate_card(assigns) do
    assigns = assign(assigns, :diff, field_diff(assigns.books, assigns.candidate.gstr2b))

    ~H"""
    <div
      id={"gst-candidate-#{@index}"}
      class="border-rule divide-rule rounded-box divide-y border"
    >
      <div class="grid grid-cols-[6rem_1fr_1.5rem_1fr] items-center gap-2 px-3 py-2">
        <span class="text-ink-subtle text-label">Candidate {@index}</span>
        <span class="text-ink-subtle text-label font-medium uppercase">Your books</span>
        <span></span>
        <span class="text-ink-subtle text-label font-medium uppercase">GSTR-2B</span>
      </div>
      <div
        :for={{label, bv, gv, agree?} <- @diff}
        class="grid grid-cols-[6rem_1fr_1.5rem_1fr] items-center gap-2 px-3 py-2"
      >
        <span class="text-ink-subtle text-label uppercase">{label}</span>
        <span class="text-base-content text-ui min-w-0 font-mono wrap-break-word tabular-nums">
          {fmt(bv)}
        </span>
        <span class="flex justify-center">
          <.icon :if={agree?} name="hero-check-mini" class="text-success size-4" />
          <.icon :if={!agree?} name="hero-x-mark-mini" class="text-error size-4" />
        </span>
        <span class={[
          "text-ui min-w-0 font-mono wrap-break-word tabular-nums",
          agree? && "text-base-content",
          !agree? && "nila-exception-mismatch"
        ]}>
          {fmt(gv)}
        </span>
      </div>
      <div :if={@show_pick} class="flex justify-end px-3 py-2">
        <.button
          variant="success"
          size="sm"
          phx-click="confirm_pair"
          phx-target={@target}
          phx-value-id={@selected_id}
          phx-value-ref={@candidate.ref}
        >This one</.button>
      </div>
    </div>
    """
  end

  attr :gstr2b, :map, required: true

  def gstr2b_card(assigns) do
    assigns =
      assign(assigns, :fields, [
        {"Document", document_label(assigns.gstr2b)},
        {"Date", assigns.gstr2b["invoice_date"]},
        {"GSTIN", assigns.gstr2b["vendor_gstin"]},
        {"Taxable", money(assigns.gstr2b["taxable_paise"])},
        {"Tax", money(tax_sum(assigns.gstr2b))},
        {"Total", money(assigns.gstr2b["total_paise"])}
      ])

    ~H"""
    <div id="gst-exception-gstr2b" class="border-rule divide-rule rounded-box divide-y border">
      <div class="text-ink-subtle text-label px-3 py-2 font-medium uppercase">
        Reported in GSTR-2B
      </div>
      <div :for={{label, value} <- @fields} class="flex items-center gap-4 px-3 py-2">
        <span class="text-ink-subtle text-label w-24 shrink-0 uppercase">{label}</span>
        <span class="text-base-content text-ui min-w-0 font-mono wrap-break-word tabular-nums">
          {fmt(value)}
        </span>
      </div>
    </div>
    """
  end

  attr :selected, :map, required: true
  attr :target, :any, default: nil

  def correction_form(assigns) do
    ~H"""
    <form phx-submit="save_correct" phx-target={@target} class="flex w-full items-end gap-2">
      <.input type="hidden" name="id" id="correct-id" value={@selected.books["id"]} />
      <div class="flex-1">
        <.input
          type="text"
          name="value"
          value={@selected.invoice_number}
          label="Corrected invoice number"
          id="correct-invoice-number"
        />
      </div>
      <.button type="submit" variant="primary" size="sm">Save & re-match</.button>
      <.button type="button" variant="ghost" size="sm" phx-click="cancel_correct" phx-target={@target}>Cancel</.button>
    </form>
    """
  end

  defp field_diff(b, g) do
    [
      {"Document", document_label(b), document_label(g)},
      {"Number", b["invoice_number"], g["invoice_number"]},
      {"Date", b["invoice_date"], g["invoice_date"]},
      {"GSTIN", b["vendor_gstin"], g["vendor_gstin"]},
      {"Taxable", money(b["taxable_paise"]), money(g["taxable_paise"])},
      {"Tax", money(tax_sum(b)), money(tax_sum(g))},
      {"Total", money(b["total_paise"]), money(g["total_paise"])}
    ]
    |> Enum.map(fn {label, bv, gv} -> {label, bv, gv, norm(bv) == norm(gv)} end)
  end

  defp facts?(selected), do: selected.candidates != [] or selected.kind == :gstr2b
  defp evidence?(selected), do: selected.images != [] or selected.evidence_gap != nil

  defp norm(v), do: v |> to_string() |> String.trim() |> String.upcase()
  defp tax_sum(inv), do: (inv["tax_paise"] || %{}) |> Map.values() |> Enum.sum()
  defp money(paise), do: format_money(paise || 0, prefix: "₹")

  defp dismiss_confirm(%{document_type: "credit_note", tax_paise: tax})
       when is_integer(tax) and tax > 0 do
    "Drop this credit note from the month? Its #{format_money(tax, prefix: "₹")} ITC reversal is removed, so the claim increases by that amount."
  end

  defp dismiss_confirm(%{tax_paise: tax}) when is_integer(tax) and tax > 0 do
    "Drop this supply from the month? The 2B ceiling falls by " <>
      "#{format_money(tax, prefix: "₹")} and the claim falls with it."
  end

  defp dismiss_confirm(_selected),
    do: "Drop this supply from the month?"

  defp dismiss_effect(%{document_type: "credit_note", tax_paise: tax})
       when is_integer(tax) and tax > 0,
       do: " · +#{format_money(tax, prefix: "₹")} claim"

  defp dismiss_effect(%{tax_paise: tax}) when is_integer(tax) and tax > 0,
    do: " · −#{format_money(tax, prefix: "₹")} claim"

  defp dismiss_effect(_selected), do: ""

  defp document_label(%{document_type: type}), do: document_label(%{"document_type" => type})
  defp document_label(%{"document_type" => "credit_note"}), do: "Credit note"
  defp document_label(%{"document_type" => "debit_note"}), do: "Debit note"
  defp document_label(_invoice), do: "Invoice"

  defp document_noun(%{document_type: "credit_note"}), do: "credit note"
  defp document_noun(%{document_type: "debit_note"}), do: "debit note"
  defp document_noun(_invoice), do: "bill"

  defp asked_label(nil), do: nil

  defp asked_label(asked_at) do
    case Date.diff(Date.utc_today(), DateTime.to_date(asked_at)) do
      0 -> "asked today"
      days -> "asked #{days}d ago"
    end
  end

  defp fmt(nil), do: "—"
  defp fmt(%Date{} = d), do: Calendar.strftime(d, "%d %b %Y")
  defp fmt(v), do: to_string(v)
  defp short_type("invoice_number_mismatch"), do: "number differs"
  defp short_type("ambiguous_matches"), do: "ambiguous"
  defp short_type("relaxed_match_weak_corroboration"), do: "weak match"
  defp short_type("fuzzy_name_weak_corroboration"), do: "name-only"
  defp short_type("no_confident_gstr2b_match"), do: "not in 2B"
  defp short_type("missing_in_books"), do: "bill not in books"
  defp short_type(other), do: other |> to_string() |> String.replace("_", " ")
end
