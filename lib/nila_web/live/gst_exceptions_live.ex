defmodule NilaWeb.GstExceptionsLive do
  use NilaWeb, :live_view

  alias Nila.Gst.{ClientMonths, Recon, Resolutions, Signoffs}
  alias Nila.Repo

  @impl true
  def mount(%{"client_id" => client_id, "period" => period}, _session, socket) do
    org = socket.assigns.current_scope.current_org

    case org && ClientMonths.get_by_period(org.id, client_id, period) do
      {:ok, month} ->
        month = Repo.preload(month, :client)

        {:ok,
         socket
         |> assign(:month, month)
         |> assign(:page_title, "Exceptions · #{month.client.name} · #{period}")
         |> assign(:correcting, nil)
         |> assign(:signed_off, signed_off?(month))
         |> load_workings()}

      _ ->
        {:ok,
         socket
         |> put_flash(:error, "That month isn't available.")
         |> push_navigate(to: ~p"/today")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :selected_id, params["exception"] || default_selected(socket))}
  end

  defp default_selected(socket) do
    case socket.assigns[:queue] do
      [first | _] -> first.id
      _ -> nil
    end
  end

  # Re-derives the effective workings from recon + resolutions, persists the
  # projection back so the register table and pack stay consistent, and builds
  # the exception queue. Called on mount and after every resolution.
  defp load_workings(socket) do
    month = socket.assigns.month
    workings = Resolutions.workings(month)

    {:ok, month} =
      ClientMonths.upsert(%{
        org_id: month.org_id,
        client_id: month.client_id,
        period: month.period,
        state: month.state,
        register_rows: workings.rows,
        recon: month.recon,
        summary: workings.summary
      })

    queue = build_queue(workings, month)

    socket
    |> assign(:month, %{month | client: socket.assigns.month.client})
    |> assign(:queue, queue)
    |> assign(:progress, progress(queue))
    |> assign(:itc, workings.itc)
  end

  # The queue is the STABLE baseline exception set (the engine's needs_human
  # before any human input), each annotated with its current decision status.
  # Building from the baseline — not the effective recon — is what lets a
  # resolved item stay visible with its outcome + an Undo, instead of vanishing.
  # Only invoice_number_mismatch is wired with verbs this pass.
  defp build_queue(workings, month) do
    (workings.baseline["needs_human"] || [])
    |> Enum.map(fn entry -> exception_item(entry, workings.decisions, month) end)
  end

  defp exception_item(entry, decisions, month) do
    books = entry["books"]
    candidates = entry["candidates"] || []
    candidate = List.first(candidates)
    verb = decisions[books["id"]]

    %{
      id: books["id"],
      type: entry["reason"]["code"],
      vendor: books["vendor_name"],
      invoice_number: books["invoice_number"],
      reason: entry["reason"]["message"],
      books: books,
      candidate: candidate,
      candidate_ref: candidate && Recon.gstr2b_ref(candidate),
      images: image_urls(books, month),
      diff: candidate && field_diff(books, candidate),
      resolvable: single_candidate_type?(entry["reason"]["code"]) and length(candidates) == 1,
      verb: verb,
      resolved: verb != nil,
      outcome: outcome_label(verb)
    }
  end

  # A single books row against a single 2B candidate — confirm/reject/correct
  # resolve it directly. `ambiguous_matches` is deliberately excluded: it has
  # multiple candidates and needs a "pick which one" surface, not a yes/no, so
  # confirming would silently ignore the other candidates ("flag, don't guess").
  defp single_candidate_type?(code) do
    code in [
      "invoice_number_mismatch",
      "relaxed_match_weak_corroboration",
      "fuzzy_name_weak_corroboration"
    ]
  end

  defp outcome_label("confirm_pair"), do: "Confirmed — same bill"
  defp outcome_label("reject_pair"), do: "Rejected — not the same"
  defp outcome_label("correct_field"), do: "Corrected & re-matched"
  defp outcome_label(_), do: nil

  defp progress(queue) do
    %{done: Enum.count(queue, & &1.resolved), total: length(queue)}
  end

  defp image_urls(books, month) do
    (books["images"] || [])
    |> Enum.map(fn path ->
      ~p"/gst/#{month.client_id}/#{month.period}/evidence/#{Path.basename(path)}"
    end)
  end

  # Field-by-field agreement between the books row and its 2B candidate — the
  # heart of the decision surface. Each entry: {label, books_value, g2b_value,
  # agree?}.
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

  @impl true
  def handle_event("select", %{"id" => id}, socket) do
    {:noreply,
     push_patch(socket,
       to:
         ~p"/gst/#{socket.assigns.month.client_id}/#{socket.assigns.month.period}/exceptions?exception=#{id}"
     )}
  end

  def handle_event(verb, _params, socket)
      when verb in ~w(confirm_pair reject_pair start_correct save_correct undo block_itc allow_itc reopen_block) and
             socket.assigns.signed_off do
    {:noreply, put_flash(socket, :error, "Month is signed off — reopen is not supported yet.")}
  end

  def handle_event("confirm_pair", %{"id" => id}, socket) do
    item = find_item(socket, id)

    record(socket, %{
      "verb" => "confirm_pair",
      "books_id" => id,
      "gstr2b_ref" => item.candidate_ref
    })
  end

  def handle_event("reject_pair", %{"id" => id}, socket) do
    item = find_item(socket, id)

    record(socket, %{
      "verb" => "reject_pair",
      "books_id" => id,
      "gstr2b_ref" => item.candidate_ref
    })
  end

  def handle_event("start_correct", %{"id" => id}, socket) do
    item = find_item(socket, id)
    {:noreply, assign(socket, :correcting, %{id: id, value: item.invoice_number || ""})}
  end

  def handle_event("cancel_correct", _params, socket) do
    {:noreply, assign(socket, :correcting, nil)}
  end

  def handle_event("save_correct", %{"id" => id, "value" => value}, socket) do
    item = find_item(socket, id)
    from = item.invoice_number

    if blank?(value) or value == from do
      {:noreply, assign(socket, :correcting, nil)}
    else
      record(
        socket,
        %{
          "verb" => "correct_field",
          "books_id" => id,
          "payload" => %{"field" => "invoice_number", "from" => from, "to" => String.trim(value)}
        },
        fn s -> assign(s, :correcting, nil) end
      )
    end
  end

  def handle_event("undo", %{"id" => id}, socket) do
    {:ok, _} =
      Resolutions.record(
        socket.assigns.month,
        %{"verb" => "reopen", "books_id" => id},
        socket.assigns.current_scope.user.id
      )

    # Stay on the item just reopened so the reviewer sees it back in play.
    {:noreply, socket |> load_workings() |> assign(:selected_id, id)}
  end

  def handle_event(verb, %{"block-id" => block_id}, socket)
      when verb in ["block_itc", "allow_itc"] do
    {:ok, _} =
      Resolutions.record(
        socket.assigns.month,
        %{"verb" => verb, "payload" => %{"block_id" => block_id}},
        socket.assigns.current_scope.user.id
      )

    {:noreply, load_workings(socket)}
  end

  def handle_event("reopen_block", %{"block-id" => block_id}, socket) do
    {:ok, _} =
      Resolutions.record(
        socket.assigns.month,
        %{"verb" => "reopen", "payload" => %{"block_id" => block_id}},
        socket.assigns.current_scope.user.id
      )

    {:noreply, load_workings(socket)}
  end

  defp record(socket, attrs, after_fun \\ & &1) do
    socket = socket |> load_workings_after(attrs) |> after_fun.()
    {:noreply, socket}
  end

  defp load_workings_after(socket, attrs) do
    {:ok, _} =
      Resolutions.record(socket.assigns.month, attrs, socket.assigns.current_scope.user.id)

    socket |> load_workings() |> advance(attrs["books_id"])
  end

  # After a decision, move focus to the next still-OPEN exception so the reviewer
  # clears the pile without navigating. The resolved item stays visible in place;
  # focus just moves on. If none are open, stay put.
  defp advance(socket, resolved_id) do
    queue = socket.assigns.queue
    idx = Enum.find_index(queue, &(&1.id == resolved_id)) || 0

    next =
      (Enum.drop(queue, idx + 1) ++ Enum.take(queue, idx))
      |> Enum.find(&(not &1.resolved))

    assign(socket, :selected_id, (next && next.id) || resolved_id)
  end

  defp find_item(socket, id), do: Enum.find(socket.assigns.queue, &(&1.id == id))
  defp blank?(v), do: is_nil(v) or String.trim(to_string(v)) == ""

  defp signed_off?(month) do
    case Signoffs.latest_signoff(month.id) do
      {:ok, _} -> true
      {:error, :not_found} -> false
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns, :selected, Enum.find(assigns.queue, &(&1.id == assigns.selected_id)))

    ~H"""
    <Layouts.app
      flash={@flash}
      page_title={@page_title}
      current_scope={@current_scope}
      current_path={assigns[:current_path]}
    >
      <div id="gst-exceptions" class="mx-auto max-w-7xl space-y-4">
        <div class="flex items-center justify-between">
          <.page_header eyebrow="GST · Exceptions" title={"#{@month.client.name} · #{@month.period}"}>
            The pile that needs a decision. Each is one tap from its scanned bill — decide it,
            and it stays here marked done. Undo anytime.
          </.page_header>
          <div class="flex shrink-0 items-center gap-4">
            <span
              :if={@progress.total > 0}
              id="gst-exceptions-progress"
              class="text-base-content/60 text-small"
            >
              {@progress.done} of {@progress.total} resolved
            </span>
            <.link
              navigate={~p"/gst/#{@month.client_id}/#{@month.period}"}
              class="hover:text-base-content text-base-content/60 text-small"
            >
              ← Full register
            </.link>
          </div>
        </div>

        <div
          :if={@progress.total > 0 and @progress.done == @progress.total}
          id="gst-exceptions-cleared"
          class="bg-success/[0.04] border-success/40 rounded-box flex items-center gap-2 border px-4 py-3"
        >
          <.icon name="hero-check-circle" class="text-success size-5 shrink-0" />
          <p class="text-base-content text-small">
            Every exception is resolved — the register is review-ready. Anything look wrong? Undo it below.
          </p>
        </div>

        {itc_panel(assigns)}

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
              <span class="flex flex-col gap-0.5">
                <span class={[
                  "text-small font-medium",
                  item.resolved && "text-base-content/50",
                  not item.resolved && "text-base-content"
                ]}>
                  {item.vendor}
                </span>
                <span class="text-base-content/50 text-fine">
                  {if item.resolved,
                    do: item.outcome,
                    else: "#{item.invoice_number || "no invoice no"} · #{short_type(item.type)}"}
                </span>
              </span>
            </button>
          </div>

          <div id="gst-exception-detail" class="border-base-300 rounded-box border p-5">
            {detail(assigns)}
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # The ITC position: the 2B ceiling (which ties to what the vendors reported),
  # Nila's recommended blocks per flagged credit, and the running claimable that
  # moves as the human confirms or overrides each block. Nila takes the position;
  # nothing is committed silently.
  defp itc_panel(%{itc: %{"blocks" => []}} = assigns) do
    ~H"""
    <div
      id="gst-itc-panel"
      class="border-base-300 rounded-box flex items-center justify-between border px-4 py-3"
    >
      <span class="text-base-content/60 text-small">Claimable ITC (2B ceiling, no blocked credits)</span>
      <span class="text-base-content text-body font-mono font-semibold">
        {itc_money(@itc["claimable_paise"])}
      </span>
    </div>
    """
  end

  defp itc_panel(assigns) do
    ~H"""
    <div id="gst-itc-panel" class="border-base-300 rounded-box border">
      <div class="border-base-300 flex items-center justify-between border-b px-4 py-3">
        <div>
          <div class="text-base-content/60 text-label font-medium uppercase">Claimable ITC</div>
          <div class="text-base-content/50 text-fine mt-0.5">
            2B ceiling {itc_money(@itc["ceiling_paise"])} − blocked {itc_money(@itc["blocked_paise"])}
          </div>
        </div>
        <div id="gst-itc-claimable" class="text-base-content text-lead font-mono font-semibold">
          {itc_money(@itc["claimable_paise"])}
        </div>
      </div>

      <div class="divide-base-300 divide-y">
        <div
          :for={b <- @itc["blocks"]}
          id={"itc-block-#{b["block_id"]}"}
          class="flex flex-wrap items-center gap-x-3 gap-y-1.5 px-4 py-2.5"
        >
          <span class="text-base-content/40 text-fine w-40 shrink-0 uppercase">
            {issue_label(b["code"])}{if b["section"], do: " · #{b["section"]}"}
          </span>
          <span class="text-base-content text-small min-w-0 flex-1 truncate">
            {b["vendor"]} · {b["invoice_number"] || "—"}
          </span>
          <span class={[
            "text-small w-24 text-right font-mono",
            b["state"] == "blocked" && "text-error",
            b["state"] != "blocked" && "text-base-content/50"
          ]}>
            −{itc_money(b["tax_paise"])}
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
            <span class="text-error text-fine font-medium">Blocked</span>
            <.button
              :if={not @signed_off}
              variant="ghost"
              size="xs"
              phx-click="reopen_block"
              phx-value-block-id={b["block_id"]}
            >
              Undo
            </.button>
          </span>
          <span :if={b["state"] == "allowed"} class="flex items-center gap-1.5">
            <span class="text-base-content/50 text-fine font-medium">Credit kept</span>
            <.button
              :if={not @signed_off}
              variant="ghost"
              size="xs"
              phx-click="reopen_block"
              phx-value-block-id={b["block_id"]}
            >
              Undo
            </.button>
          </span>
        </div>
      </div>
    </div>
    """
  end

  # ITC figures show paise — tax precision matters for a claimable number the
  # firm will file, unlike the register's rupee-rounded display.
  defp itc_money(paise), do: Nila.Formatters.format_money_with_paise(paise || 0)

  defp detail(%{selected: nil} = assigns) do
    ~H"""
    <p class="text-base-content/60 text-small">Select an exception from the queue.</p>
    """
  end

  defp detail(assigns) do
    ~H"""
    <div class="space-y-5">
      <div>
        <h3 class="text-base-content text-body font-semibold">
          {@selected.invoice_number || "—"} · {@selected.vendor}
        </h3>
        <p class="text-base-content/70 text-small mt-1">{@selected.reason}</p>
      </div>

      <div :if={@selected.diff} class="border-base-300 divide-base-300 rounded-box divide-y border">
        <div class="grid grid-cols-[6rem_1fr_1.5rem_1fr] items-center gap-2 px-3 py-2">
          <span></span>
          <span class="text-base-content/60 text-label font-medium uppercase">Your books</span>
          <span></span>
          <span class="text-base-content/60 text-label font-medium uppercase">GSTR-2B</span>
        </div>
        <div
          :for={{label, bv, gv, agree?} <- @selected.diff}
          class="grid grid-cols-[6rem_1fr_1.5rem_1fr] items-center gap-2 px-3 py-2"
        >
          <span class="text-base-content/50 text-fine uppercase">{label}</span>
          <span class="text-base-content text-small font-mono">{fmt(bv)}</span>
          <span class="flex justify-center">
            <.icon
              :if={agree?}
              name="hero-check-mini"
              class="text-success size-4"
            />
            <.icon
              :if={!agree?}
              name="hero-x-mark-mini"
              class="text-error size-4"
            />
          </span>
          <span class={[
            "text-small font-mono",
            agree? && "text-base-content",
            !agree? && "text-error"
          ]}>
            {fmt(gv)}
          </span>
        </div>
      </div>

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
        :if={@selected.resolvable and not @selected.resolved and not @signed_off}
        class="border-base-300 flex flex-wrap gap-2 border-t pt-4"
      >
        <%= if @correcting && @correcting.id == @selected.id do %>
          <form phx-submit="save_correct" class="flex w-full items-end gap-2">
            <.input type="hidden" name="id" id="correct-id" value={@selected.id} />
            <div class="flex-1">
              <.input
                type="text"
                name="value"
                value={@correcting.value}
                label="Corrected invoice number"
                id="correct-invoice-number"
              />
            </div>
            <.button type="submit" variant="primary" size="sm">Save & re-match</.button>
            <.button type="button" variant="ghost" size="sm" phx-click="cancel_correct">
              Cancel
            </.button>
          </form>
        <% else %>
          <.button variant="success" size="sm" phx-click="confirm_pair" phx-value-id={@selected.id}>
            Confirm — same bill
          </.button>
          <.button variant="outline" size="sm" phx-click="reject_pair" phx-value-id={@selected.id}>
            Reject — not the same
          </.button>
          <.button variant="ghost" size="sm" phx-click="start_correct" phx-value-id={@selected.id}>
            Correct the number
          </.button>
        <% end %>
      </div>

      <div
        :if={not @selected.resolvable and not @selected.resolved}
        class="border-base-300 border-t pt-4"
      >
        <p class="text-base-content/50 text-fine">
          This exception type isn't wired for one-tap resolution yet — review in the full register.
        </p>
      </div>
    </div>
    """
  end

  defp fmt(nil), do: "—"
  defp fmt(%Date{} = d), do: Calendar.strftime(d, "%d %b %Y")
  defp fmt(v), do: to_string(v)

  defp short_type("invoice_number_mismatch"), do: "number differs"
  defp short_type("ambiguous_matches"), do: "ambiguous"
  defp short_type("relaxed_match_weak_corroboration"), do: "weak match"
  defp short_type("fuzzy_name_weak_corroboration"), do: "name-only"
  defp short_type(other), do: other |> to_string() |> String.replace("_", " ")
end
