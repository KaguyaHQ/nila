defmodule NilaWeb.GstExceptionsLive do
  use NilaWeb, :live_view

  alias Nila.Gst.Chase
  alias Nila.Gst.Filing.Signoffs
  alias Nila.Gst.Purchase.{Reconciliation, Resolutions}
  alias Nila.Gst.Purchase.Months, as: ClientMonths
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
         |> assign(:draft, nil)
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

  # The queue is the stable machine baseline. Resolved items stay visible with
  # their audited outcome and Undo, while effective candidates reflect rejects.
  defp build_queue(workings, month) do
    asked_at = last_ask_at(month)

    books_items =
      (workings.baseline["needs_human"] || []) ++
        (workings.baseline["in_books_not_2b"] || [])

    books_queue =
      Enum.map(books_items, fn entry ->
        exception_item(entry, workings, month)
      end)

    gstr2b_queue =
      Enum.map(workings.baseline["in_2b_not_books"] || [], fn entry ->
        gstr2b_item(entry, workings.gstr2b_decisions, asked_at)
      end)

    books_queue ++ gstr2b_queue
  end

  defp exception_item(entry, workings, month) do
    books = entry["books"]
    type = entry["reason"]["code"]
    candidates = effective_candidates(workings.recon, books["id"], entry["candidates"] || [])
    verb = workings.decisions[books["id"]]
    accepted_reason = workings.accepted_reasons[books["id"]]
    effective_bucket = effective_books_bucket(workings.recon, books["id"])

    resolved =
      accepted_reason != nil or
        (verb in ["confirm_pair", "correct_field"] and
           effective_bucket in ["matched", "value_mismatch"])

    %{
      id: books["id"],
      kind: :books,
      type: type,
      vendor: books["vendor_name"],
      invoice_number: books["invoice_number"],
      reason: entry["reason"]["message"],
      books: books,
      gstr2b: nil,
      candidates: candidate_views(books, candidates),
      images: image_urls(books, month),
      action: books_action(type, candidates),
      verb: verb,
      resolved: resolved,
      outcome: outcome_label(verb, type, accepted_reason),
      asked_at: nil
    }
  end

  defp gstr2b_item(entry, decisions, asked_at) do
    gstr2b = entry["gstr2b"] || entry
    ref = Reconciliation.gstr2b_ref(gstr2b)
    verb = decisions[ref]

    %{
      id: "g2b-#{ref}",
      kind: :gstr2b,
      type: get_in(entry, ["reason", "code"]) || "missing_in_books",
      vendor: gstr2b["vendor_name"],
      invoice_number: gstr2b["invoice_number"],
      reason: get_in(entry, ["reason", "message"]) || "This GSTR-2B bill is not in the books.",
      books: nil,
      gstr2b: gstr2b,
      gstr2b_ref: ref,
      candidates: [],
      images: [],
      action: :gstr2b,
      verb: verb,
      resolved: verb == "dismiss_2b",
      outcome: outcome_label(verb, "missing_in_books", nil),
      asked_at: asked_at
    }
  end

  defp effective_candidates(recon, books_id, fallback) do
    case Enum.find(recon["needs_human"] || [], &(get_in(&1, ["books", "id"]) == books_id)) do
      nil -> fallback
      entry -> entry["candidates"] || []
    end
  end

  defp effective_books_bucket(recon, books_id) do
    Enum.find_value(~w(matched value_mismatch needs_human in_books_not_2b), fn bucket ->
      if Enum.any?(recon[bucket] || [], &(get_in(&1, ["books", "id"]) == books_id)),
        do: bucket
    end)
  end

  defp candidate_views(books, candidates) do
    Enum.map(candidates, fn candidate ->
      %{
        gstr2b: candidate,
        ref: Reconciliation.gstr2b_ref(candidate),
        diff: field_diff(books, candidate)
      }
    end)
  end

  defp books_action("ambiguous_matches", [_ | _]), do: :ambiguous

  defp books_action(type, [_candidate])
       when type in [
              "invoice_number_mismatch",
              "relaxed_match_weak_corroboration",
              "fuzzy_name_weak_corroboration"
            ],
       do: :pair

  defp books_action(_type, _candidates), do: :unmatched

  defp outcome_label("confirm_pair", "ambiguous_matches", _reason),
    do: "Matched to the chosen 2B row"

  defp outcome_label("confirm_pair", _type, _reason), do: "Confirmed — same bill"
  defp outcome_label("correct_field", _type, _reason), do: "Corrected & re-matched"

  defp outcome_label("accept_unmatched", _type, "await_2b"),
    do: "Kept — awaiting vendor's 2B"

  defp outcome_label("accept_unmatched", _type, "not_claimable"),
    do: "Not claimable this month"

  defp outcome_label("dismiss_2b", _type, _reason), do: "Dismissed — not ours"
  defp outcome_label(_verb, _type, _reason), do: nil

  defp last_ask_at(month) do
    case Chase.last_ask(month.org_id, month.client_id, month.period) do
      {:ok, ask} -> ask.inserted_at
      {:error, :not_found} -> nil
    end
  end

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
      when verb in ~w(confirm_pair reject_pair reject_all accept_unmatched dismiss_2b start_correct save_correct undo block_itc allow_itc reopen_block) and
             socket.assigns.signed_off do
    {:noreply,
     put_flash(
       socket,
       :error,
       "Month is signed off — a senior must reopen it from the month page."
     )}
  end

  def handle_event("confirm_pair", %{"id" => id} = params, socket) do
    item = find_item(socket, id)
    ref = params["ref"] || hd(item.candidates).ref

    record(socket, %{
      "verb" => "confirm_pair",
      "books_id" => id,
      "gstr2b_ref" => ref
    })
  end

  def handle_event("reject_pair", %{"id" => id}, socket) do
    item = find_item(socket, id)

    record(socket, %{
      "verb" => "reject_pair",
      "books_id" => id,
      "gstr2b_ref" => hd(item.candidates).ref
    })
  end

  def handle_event("reject_all", %{"id" => id}, socket) do
    item = find_item(socket, id)

    {:ok, _resolutions} =
      Repo.transact(fn ->
        Enum.reduce_while(item.candidates, {:ok, []}, fn candidate, {:ok, resolutions} ->
          case Resolutions.record(
                 socket.assigns.month,
                 %{
                   "verb" => "reject_pair",
                   "books_id" => id,
                   "gstr2b_ref" => candidate.ref
                 },
                 socket.assigns.current_scope.user.id
               ) do
            {:ok, resolution} -> {:cont, {:ok, [resolution | resolutions]}}
            {:error, changeset} -> {:halt, {:error, changeset}}
          end
        end)
      end)

    {:noreply, socket |> load_workings() |> assign(:selected_id, id)}
  end

  def handle_event("accept_unmatched", %{"id" => id, "reason" => reason}, socket)
      when reason in ~w(await_2b not_claimable) do
    record(socket, %{
      "verb" => "accept_unmatched",
      "books_id" => id,
      "payload" => %{"reason" => reason}
    })
  end

  def handle_event("accept_unmatched", _params, socket), do: {:noreply, socket}

  def handle_event("dismiss_2b", %{"id" => id}, socket) do
    item = find_item(socket, id)

    record(socket, %{
      "verb" => "dismiss_2b",
      "gstr2b_ref" => item.gstr2b_ref
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
    item = find_item(socket, id)

    target =
      case item.kind do
        :books -> %{"books_id" => id}
        :gstr2b -> %{"gstr2b_ref" => item.gstr2b_ref}
      end

    {:ok, _} =
      Resolutions.record(
        socket.assigns.month,
        Map.put(target, "verb", "reopen"),
        socket.assigns.current_scope.user.id
      )

    {:noreply, socket |> load_workings() |> assign(:selected_id, id)}
  end

  def handle_event("open-ask", %{"id" => id}, socket) do
    item = find_item(socket, id)
    month = socket.assigns.month

    body =
      Chase.draft(
        :missing_bills,
        socket.assigns.current_scope.current_org,
        month.client,
        month.period,
        %{
          in_2b_not_books: [%{"gstr2b" => item.gstr2b}],
          sequence_issues: []
        }
      )

    {:noreply, assign(socket, :draft, %{body: body, item_id: id})}
  end

  def handle_event("close-ask", _params, socket) do
    {:noreply, assign(socket, :draft, nil)}
  end

  def handle_event("mark-ask-sent", _params, socket) do
    %{month: month, draft: draft, current_scope: scope} = socket.assigns

    {:ok, _ask} =
      Chase.record_ask(
        %{org_id: month.org_id, client_id: month.client_id, sent_by_id: scope.user.id},
        %{kind: "missing_bills", period: month.period, body: draft.body, channel: "manual"}
      )

    {:noreply,
     socket
     |> assign(:draft, nil)
     |> load_workings()
     |> assign(:selected_id, draft.item_id)
     |> put_flash(:info, "Ask logged.")}
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

    resolved_id = attrs["books_id"] || "g2b-#{attrs["gstr2b_ref"]}"
    socket |> load_workings() |> advance(resolved_id)
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
              <span class="flex min-w-0 flex-col gap-0.5">
                <span class={[
                  "text-small font-medium",
                  item.resolved && "text-base-content/50",
                  not item.resolved && "text-base-content"
                ]}>
                  {item.vendor}
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
            {detail(assigns)}
          </div>
        </div>
      </div>

      <.modal
        :if={@draft}
        id="gst-missing-bill-modal"
        title="Ask for the missing bill"
        on_close="close-ask"
        class="max-w-2xl"
      >
        <div class="space-y-4">
          <pre
            id="gst-missing-bill-draft"
            class="bg-base-200/40 border-base-300 rounded-box text-base-content text-small overflow-x-auto border p-4 font-sans whitespace-pre-wrap"
          >{@draft.body}</pre>
          <div class="flex items-center justify-end gap-2">
            <.button
              id="gst-missing-bill-copy"
              variant="soft"
              size="sm"
              phx-hook=".CopyMissingBillDraft"
              type="button"
            >
              <.icon name="hero-clipboard-document" class="size-4" /> Copy
            </.button>
            <.button
              id="gst-missing-bill-mark-sent"
              variant="primary"
              size="sm"
              phx-click="mark-ask-sent"
            >
              Mark as sent
            </.button>
          </div>
          <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyMissingBillDraft">
            export default {
              mounted() {
                this.el.addEventListener("click", () => {
                  const body = document.getElementById("gst-missing-bill-draft")
                  if (body) navigator.clipboard.writeText(body.textContent)
                })
              }
            }
          </script>
        </div>
      </.modal>
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
        <p :if={asked_label(@selected.asked_at)} class="text-fine text-moon mt-1 font-medium">
          {asked_label(@selected.asked_at)}
        </p>
      </div>

      <div :if={@selected.candidates != []} id="gst-exception-candidates" class="space-y-3">
        <.candidate_card
          :for={{candidate, index} <- Enum.with_index(@selected.candidates, 1)}
          candidate={candidate}
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
        >
          None of these
        </.button>
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
          >
            Confirm — same bill
          </.button>
          <.button
            :if={@selected.action == :pair}
            variant="outline"
            size="sm"
            phx-click="reject_pair"
            phx-value-id={@selected.id}
          >
            Reject — not the same
          </.button>
          <.button
            :if={@selected.action == :unmatched}
            id="gst-accept-await-2b"
            variant="outline"
            size="sm"
            phx-click="accept_unmatched"
            phx-value-id={@selected.id}
            phx-value-reason="await_2b"
          >
            Vendor hasn't filed it yet
          </.button>
          <.button
            :if={@selected.action == :unmatched}
            id="gst-accept-not-claimable"
            variant="outline"
            size="sm"
            phx-click="accept_unmatched"
            phx-value-id={@selected.id}
            phx-value-reason="not_claimable"
          >
            Not claimable this month
          </.button>
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
        >
          Ask the client for the bill
        </.button>
        <.button
          id="gst-dismiss-2b"
          variant="outline"
          size="sm"
          phx-click="dismiss_2b"
          phx-value-id={@selected.id}
        >
          Not ours / ignore
        </.button>
      </div>
    </div>
    """
  end

  attr :candidate, :map, required: true
  attr :index, :integer, required: true
  attr :selected_id, :string, required: true
  attr :show_pick, :boolean, required: true

  defp candidate_card(assigns) do
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
        :for={{label, bv, gv, agree?} <- @candidate.diff}
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
        >
          This one
        </.button>
      </div>
    </div>
    """
  end

  attr :gstr2b, :map, required: true

  defp gstr2b_card(assigns) do
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

  defp correction_form(assigns) do
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
      <.button type="button" variant="ghost" size="sm" phx-click="cancel_correct">
        Cancel
      </.button>
    </form>
    """
  end

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
