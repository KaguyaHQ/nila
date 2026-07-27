defmodule NilaWeb.Components.Gst.Exceptions.Surface do
  use NilaWeb, :html

  @moduledoc "Queue, detail, and candidate presentation for the GST exception workbench."

  attr :queue, :list, required: true
  attr :selected_id, :any, default: nil
  attr :selected, :any, default: nil
  attr :signed_off, :boolean, required: true
  attr :correcting, :any, default: nil

  def exception_surface(assigns) do
    ~H"""
    <div
      :if={@queue == []}
      id="gst-exceptions-empty"
      class="border-base-300 rounded-box border border-dashed p-12 text-center"
    >
      <.icon name="hero-check-circle" class="text-success mx-auto size-10" />
      <p class="text-base-content text-body mt-3 font-medium">No exceptions</p>
      <p class="text-base-content/60 text-small mt-1">
        The engine matched every invoice confidently — nothing needs a human decision.
      </p>
    </div>

    <div :if={@queue != []} class="grid gap-4 lg:grid-cols-[20rem_1fr]">
      <div
        id="gst-exception-queue"
        class="border-base-300 divide-base-300 rounded-box divide-y border"
      >
        <button
          :for={item <- @queue}
          type="button"
          id={"queue-#{item.id}"}
          phx-click="select"
          phx-value-id={item.id}
          class={[
            "flex w-full items-start gap-2 px-3 py-2.5 text-left transition",
            item.id == @selected_id && "bg-base-200",
            item.id != @selected_id && "hover:bg-base-200/50"
          ]}
        >
          <.icon
            :if={item.resolved}
            name="hero-check-circle-mini"
            class="text-success mt-0.5 size-4 shrink-0"
          />
          <span :if={not item.resolved} class="bg-warning mt-1.5 size-2 shrink-0 rounded-full" />
          <span class="flex min-w-0 flex-1 flex-col gap-0.5">
            <span class="flex items-baseline gap-2">
              <span class={[
                "text-small min-w-0 flex-1 truncate font-medium",
                item.resolved && "text-base-content/50",
                not item.resolved && "text-base-content"
              ]}>
                {item.vendor}
              </span>
              <span
                :if={item.tax_paise > 0}
                id={"queue-tax-#{item.id}"}
                class={[
                  "text-fine shrink-0 font-mono",
                  (item.resolved && "text-base-content/40") || "text-base-content/70"
                ]}
              >
                {format_money(item.tax_paise, prefix: "₹")}
              </span>
            </span>
            <span class="text-base-content/50 text-fine truncate">
              {if item.resolved,
                do: item.outcome,
                else: "#{item.invoice_number || "no invoice no"} · #{short_type(item.type)}"}
            </span>
          </span>
        </button>
      </div>

      <div id="gst-exception-detail" class="border-base-300 rounded-box border p-5">
        <.detail selected={@selected} signed_off={@signed_off} correcting={@correcting} />
      </div>
    </div>
    """
  end

  attr :selected, :any, default: nil
  attr :signed_off, :boolean, required: true
  attr :correcting, :any, default: nil

  def detail(%{selected: nil} = assigns) do
    ~H"""
    <p class="text-base-content/60 text-small">Select an exception from the queue.</p>
    """
  end

  def detail(assigns) do
    ~H"""
    <div class="space-y-5">
      <div>
        <h3 class="text-base-content text-body flex flex-wrap items-baseline gap-x-3 font-semibold">
          <span>{@selected.invoice_number || "—"} · {@selected.vendor}</span>
          <span :if={@selected.tax_paise > 0} id="gst-exception-tax" class="text-small font-mono">
            {format_money(@selected.tax_paise, prefix: "₹")} tax at stake
          </span>
        </h3>
        <p class="text-base-content/70 text-small mt-1">{@selected.reason}</p>
        <p :if={asked_label(@selected.asked_at)} class="text-fine text-moon mt-1 font-medium">
          {asked_label(@selected.asked_at)}
        </p>
      </div>

      <div :if={@selected.candidates != []} id="gst-exception-candidates" class="space-y-3">
        <.candidate_card
          :for={{candidate, index} <- Enum.with_index(@selected.candidates, 1)}
          candidate={candidate}
          books={@selected.books}
          index={index}
          selected_id={@selected.id}
          show_pick={@selected.action == :ambiguous and not @selected.resolved and not @signed_off}
        />
      </div>

      <.gstr2b_card :if={@selected.kind == :gstr2b} gstr2b={@selected.gstr2b} />

      <div :if={@selected.images != []} id="gst-exception-evidence" class="space-y-2">
        <div class="text-base-content/60 text-label font-medium uppercase">Scanned bill</div>
        <img
          :for={url <- @selected.images}
          src={url}
          alt="Scanned bill"
          class="border-base-300 rounded-box w-full max-w-lg border"
        />
      </div>

      <div
        :if={@selected.resolved}
        id="gst-exception-outcome"
        class="border-base-300 flex flex-wrap items-center gap-3 border-t pt-4"
      >
        <span class="text-small text-success flex items-center gap-1.5 font-medium">
          <.icon name="hero-check-circle-mini" class="size-4" /> {@selected.outcome}
        </span>
        <.button
          :if={not @signed_off}
          variant="ghost"
          size="sm"
          phx-click="undo"
          phx-value-id={@selected.id}
        >
          <.icon name="hero-arrow-uturn-left-mini" class="size-4" /> Undo
        </.button>
      </div>

      <div
        :if={@selected.action == :ambiguous and not @selected.resolved and not @signed_off}
        class="border-base-300 flex border-t pt-4"
      >
        <.button
          id="gst-reject-all-candidates"
          variant="outline"
          size="sm"
          phx-click="reject_all"
          phx-value-id={@selected.id}
        >None of these</.button>
      </div>

      <div
        :if={
          @selected.kind == :books and @selected.action in [:pair, :unmatched] and
            not @selected.resolved and not @signed_off
        }
        class="border-base-300 flex flex-wrap gap-2 border-t pt-4"
      >
        <%= if @correcting && @correcting.id == @selected.id do %>
          <.correction_form selected={@selected} />
        <% else %>
          <.button
            :if={@selected.action == :pair}
            variant="success"
            size="sm"
            phx-click="confirm_pair"
            phx-value-id={@selected.id}
          >Confirm — same bill</.button>
          <.button
            :if={@selected.action == :pair}
            variant="outline"
            size="sm"
            phx-click="reject_pair"
            phx-value-id={@selected.id}
          >Reject — not the same</.button>
          <.button
            :if={@selected.action == :unmatched}
            id="gst-accept-await-2b"
            variant="outline"
            size="sm"
            phx-click="accept_unmatched"
            phx-value-id={@selected.id}
            phx-value-reason="await_2b"
          >Vendor hasn't filed it yet</.button>
          <.button
            :if={@selected.action == :unmatched}
            id="gst-accept-not-claimable"
            variant="outline"
            size="sm"
            phx-click="accept_unmatched"
            phx-value-id={@selected.id}
            phx-value-reason="not_claimable"
          >Not claimable this month</.button>
          <.button variant="ghost" size="sm" phx-click="start_correct" phx-value-id={@selected.id}>
            Correct the number
          </.button>
        <% end %>
      </div>

      <div
        :if={@selected.action == :gstr2b and not @selected.resolved and not @signed_off}
        class="border-base-300 flex flex-wrap gap-2 border-t pt-4"
      >
        <.button
          id="gst-ask-client"
          variant="primary"
          size="sm"
          phx-click="open-ask"
          phx-value-id={@selected.id}
        >Ask the client for the bill</.button>
        <.button
          id="gst-dismiss-2b"
          variant="outline"
          size="sm"
          phx-click="dismiss_2b"
          phx-value-id={@selected.id}
        >Not ours / ignore</.button>
      </div>
    </div>
    """
  end

  attr :candidate, :map, required: true
  attr :books, :map, required: true
  attr :index, :integer, required: true
  attr :selected_id, :string, required: true
  attr :show_pick, :boolean, required: true

  def candidate_card(assigns) do
    assigns = assign(assigns, :diff, field_diff(assigns.books, assigns.candidate.gstr2b))

    ~H"""
    <div
      id={"gst-candidate-#{@index}"}
      class="border-base-300 divide-base-300 rounded-box divide-y border"
    >
      <div class="grid grid-cols-[6rem_1fr_1.5rem_1fr] items-center gap-2 px-3 py-2">
        <span class="text-base-content/50 text-fine">Candidate {@index}</span>
        <span class="text-base-content/60 text-label font-medium uppercase">Your books</span>
        <span></span>
        <span class="text-base-content/60 text-label font-medium uppercase">GSTR-2B</span>
      </div>
      <div
        :for={{label, bv, gv, agree?} <- @diff}
        class="grid grid-cols-[6rem_1fr_1.5rem_1fr] items-center gap-2 px-3 py-2"
      >
        <span class="text-base-content/50 text-fine uppercase">{label}</span>
        <span class="text-base-content text-small font-mono">{fmt(bv)}</span>
        <span class="flex justify-center">
          <.icon :if={agree?} name="hero-check-mini" class="text-success size-4" />
          <.icon :if={!agree?} name="hero-x-mark-mini" class="text-error size-4" />
        </span>
        <span class={[
          "text-small font-mono",
          agree? && "text-base-content",
          !agree? && "text-error"
        ]}>
          {fmt(gv)}
        </span>
      </div>
      <div :if={@show_pick} class="flex justify-end px-3 py-2">
        <.button
          variant="success"
          size="sm"
          phx-click="confirm_pair"
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
        {"Date", assigns.gstr2b["invoice_date"]},
        {"GSTIN", assigns.gstr2b["vendor_gstin"]},
        {"Taxable", money(assigns.gstr2b["taxable_paise"])},
        {"Tax", money(tax_sum(assigns.gstr2b))},
        {"Total", money(assigns.gstr2b["total_paise"])}
      ])

    ~H"""
    <div id="gst-exception-gstr2b" class="border-base-300 divide-base-300 rounded-box divide-y border">
      <div class="text-base-content/60 text-label px-3 py-2 font-medium uppercase">
        Reported in GSTR-2B
      </div>
      <div :for={{label, value} <- @fields} class="flex items-center gap-4 px-3 py-2">
        <span class="text-base-content/50 text-fine w-24 uppercase">{label}</span>
        <span class="text-base-content text-small font-mono">{fmt(value)}</span>
      </div>
    </div>
    """
  end

  attr :selected, :map, required: true

  def correction_form(assigns) do
    ~H"""
    <form phx-submit="save_correct" class="flex w-full items-end gap-2">
      <.input type="hidden" name="id" id="correct-id" value={@selected.id} />
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
      <.button type="button" variant="ghost" size="sm" phx-click="cancel_correct">Cancel</.button>
    </form>
    """
  end

  defp field_diff(b, g) do
    [
      {"Invoice no", b["invoice_number"], g["invoice_number"]},
      {"Date", b["invoice_date"], g["invoice_date"]},
      {"GSTIN", b["vendor_gstin"], g["vendor_gstin"]},
      {"Taxable", money(b["taxable_paise"]), money(g["taxable_paise"])},
      {"Tax", money(tax_sum(b)), money(tax_sum(g))},
      {"Total", money(b["total_paise"]), money(g["total_paise"])}
    ]
    |> Enum.map(fn {label, bv, gv} -> {label, bv, gv, norm(bv) == norm(gv)} end)
  end

  defp norm(v), do: v |> to_string() |> String.trim() |> String.upcase()
  defp tax_sum(inv), do: (inv["tax_paise"] || %{}) |> Map.values() |> Enum.sum()
  defp money(paise), do: format_money(paise || 0, prefix: "₹")

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
