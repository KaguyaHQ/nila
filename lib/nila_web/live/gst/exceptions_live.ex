defmodule NilaWeb.Gst.ExceptionsLive do
  use NilaWeb, :live_view

  alias Nila.Gst.Chase
  alias Nila.Gst.Filing.Signoffs
  alias Nila.Gst.Purchase.{Reconciliation, Resolutions}
  alias Nila.Gst.Purchase.Months, as: ClientMonths
  alias NilaWeb.Components.Gst.Exceptions.{Itc, Modal, Surface}

  @impl true
  def mount(%{"client_id" => client_id, "period" => period}, _session, socket) do
    org = socket.assigns.current_scope.current_org

    case org && ClientMonths.get_by_period_with_client(org.id, client_id, period) do
      {:ok, month} ->
        workings = Resolutions.workings(month)

        {:ok,
         socket
         |> assign(:page_title, "Exceptions · #{month.client.name} · #{period}")
         |> assign(:correcting, nil)
         |> assign(:draft, nil)
         |> assign_workings(month, workings)}

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

  defp assign_workings(socket, month, workings) do
    queue = build_queue(workings, month)

    socket
    |> assign(:month, month)
    |> assign(:signed_off, signed_off?(month))
    |> assign(:queue, queue)
    |> assign(:progress, progress(queue))
    |> assign(:itc, workings.itc)
  end

  defp build_queue(workings, month) do
    asked_at = last_ask_at(month)

    books_items =
      (workings.baseline["needs_human"] || []) ++
        (workings.baseline["in_books_not_2b"] || [])

    books_queue = Enum.map(books_items, &exception_item(&1, workings, month))

    gstr2b_queue =
      Enum.map(workings.baseline["in_2b_not_books"] || [], fn entry ->
        gstr2b_item(entry, workings.gstr2b_decisions, asked_at)
      end)

    # Biggest exposure first. The queue used to run in extraction order, which
    # spends the reviewer's freshest attention on whatever happened to be
    # scanned first rather than on the ₹48,802 decision.
    Enum.sort_by(books_queue ++ gstr2b_queue, & &1.tax_paise, :desc)
  end

  defp tax_total(nil), do: 0

  defp tax_total(invoice) do
    tax = invoice["tax_paise"] || %{}
    (tax["cgst"] || 0) + (tax["sgst"] || 0) + (tax["igst"] || 0)
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
      candidates: candidate_views(candidates),
      images: image_urls(books, month),
      tax_paise: tax_total(books),
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
      tax_paise: tax_total(gstr2b),
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
      if Enum.any?(recon[bucket] || [], &(get_in(&1, ["books", "id"]) == books_id)), do: bucket
    end)
  end

  defp candidate_views(candidates) do
    Enum.map(candidates, fn candidate ->
      %{gstr2b: candidate, ref: Reconciliation.gstr2b_ref(candidate)}
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

  defp outcome_label("confirm_pair", "ambiguous_matches", _), do: "Matched to the chosen 2B row"
  defp outcome_label("confirm_pair", _, _), do: "Confirmed — same bill"
  defp outcome_label("correct_field", _, _), do: "Corrected & re-matched"
  defp outcome_label("accept_unmatched", _, "await_2b"), do: "Kept — awaiting vendor's 2B"
  defp outcome_label("accept_unmatched", _, "not_claimable"), do: "Not claimable this month"
  defp outcome_label("dismiss_2b", _, _), do: "Dismissed — not ours"
  defp outcome_label(_, _, _), do: nil

  defp last_ask_at(month) do
    case Chase.last_ask(month.org_id, month.client_id, month.period) do
      {:ok, ask} -> ask.inserted_at
      {:error, :not_found} -> nil
    end
  end

  defp progress(queue), do: %{done: Enum.count(queue, & &1.resolved), total: length(queue)}

  defp image_urls(books, month) do
    Enum.map(books["images"] || [], fn path ->
      ~p"/gst/#{month.client_id}/#{month.period}/evidence/#{Path.basename(path)}"
    end)
  end

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
    record(socket, %{"verb" => "confirm_pair", "books_id" => id, "gstr2b_ref" => ref})
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
    attrs_list =
      socket
      |> find_item(id)
      |> Map.fetch!(:candidates)
      |> Enum.map(fn candidate ->
        %{"verb" => "reject_pair", "books_id" => id, "gstr2b_ref" => candidate.ref}
      end)

    case Resolutions.record_many_and_refresh(
           socket.assigns.month,
           attrs_list,
           socket.assigns.current_scope.user.id
         ) do
      {:ok, result} ->
        {:noreply,
         socket |> assign_workings(result.month, result.workings) |> assign(:selected_id, id)}

      {:error, :signed_off} ->
        signed_off(socket)
    end
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
    record(socket, %{"verb" => "dismiss_2b", "gstr2b_ref" => item.gstr2b_ref})
  end

  def handle_event("start_correct", %{"id" => id}, socket) do
    item = find_item(socket, id)
    {:noreply, assign(socket, :correcting, %{id: id, value: item.invoice_number || ""})}
  end

  def handle_event("cancel_correct", _params, socket),
    do: {:noreply, assign(socket, :correcting, nil)}

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
      if item.kind == :books, do: %{"books_id" => id}, else: %{"gstr2b_ref" => item.gstr2b_ref}

    case Resolutions.record_and_refresh(
           socket.assigns.month,
           Map.put(target, "verb", "reopen"),
           socket.assigns.current_scope.user.id
         ) do
      {:ok, result} ->
        {:noreply,
         socket |> assign_workings(result.month, result.workings) |> assign(:selected_id, id)}

      {:error, :signed_off} ->
        signed_off(socket)
    end
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
        %{in_2b_not_books: [%{"gstr2b" => item.gstr2b}], sequence_issues: []}
      )

    {:noreply, assign(socket, :draft, %{body: body, item_id: id})}
  end

  def handle_event("close-ask", _params, socket), do: {:noreply, assign(socket, :draft, nil)}

  def handle_event("mark-ask-sent", _params, socket) do
    %{month: month, draft: draft, current_scope: scope} = socket.assigns

    {:ok, _} =
      Chase.record_ask(
        %{org_id: month.org_id, client_id: month.client_id, sent_by_id: scope.user.id},
        %{kind: "missing_bills", period: month.period, body: draft.body, channel: "manual"}
      )

    workings = Resolutions.workings(month)

    {:noreply,
     socket
     |> assign(:draft, nil)
     |> assign_workings(month, workings)
     |> assign(:selected_id, draft.item_id)
     |> put_flash(:info, "Ask logged.")}
  end

  def handle_event(verb, %{"block-id" => block_id}, socket)
      when verb in ["block_itc", "allow_itc"] do
    refresh_without_advancing(socket, %{"verb" => verb, "payload" => %{"block_id" => block_id}})
  end

  def handle_event("reopen_block", %{"block-id" => block_id}, socket) do
    refresh_without_advancing(socket, %{
      "verb" => "reopen",
      "payload" => %{"block_id" => block_id}
    })
  end

  defp record(socket, attrs, after_fun \\ & &1) do
    socket = socket |> record_and_assign(attrs) |> after_fun.()
    {:noreply, socket}
  end

  defp record_and_assign(socket, attrs) do
    case Resolutions.record_and_refresh(
           socket.assigns.month,
           attrs,
           socket.assigns.current_scope.user.id
         ) do
      {:ok, result} ->
        resolved_id = attrs["books_id"] || "g2b-#{attrs["gstr2b_ref"]}"
        socket |> assign_workings(result.month, result.workings) |> advance(resolved_id)

      {:error, :signed_off} ->
        socket |> assign(:signed_off, true) |> put_flash(:error, signed_off_message())
    end
  end

  defp refresh_without_advancing(socket, attrs) do
    case Resolutions.record_and_refresh(
           socket.assigns.month,
           attrs,
           socket.assigns.current_scope.user.id
         ) do
      {:ok, result} -> {:noreply, assign_workings(socket, result.month, result.workings)}
      {:error, :signed_off} -> signed_off(socket)
    end
  end

  defp signed_off(socket) do
    {:noreply, socket |> assign(:signed_off, true) |> put_flash(:error, signed_off_message())}
  end

  defp signed_off_message,
    do: "Month is signed off — a senior must reopen it from the month page."

  defp advance(socket, resolved_id) do
    queue = socket.assigns.queue
    idx = Enum.find_index(queue, &(&1.id == resolved_id)) || 0
    next = (Enum.drop(queue, idx + 1) ++ Enum.take(queue, idx)) |> Enum.find(&(not &1.resolved))
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
            >← Full register</.link>
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

        <Itc.itc_panel itc={@itc} signed_off={@signed_off} />
        <Surface.exception_surface
          queue={@queue}
          selected_id={@selected_id}
          selected={@selected}
          signed_off={@signed_off}
          correcting={@correcting}
        />
      </div>

      <Modal.missing_bill_modal draft={@draft} />
    </Layouts.app>
    """
  end
end
