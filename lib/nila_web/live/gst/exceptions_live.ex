defmodule NilaWeb.Gst.ExceptionsLive do
  use NilaWeb, :live_view

  alias Nila.Gst.Chase
  alias Nila.Gst.Filing.Signoffs
  alias Nila.Gst.Intake.Dumps
  alias Nila.Gst.Purchase.{Reconciliation, Register, Resolutions}
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
         |> assign(:evidence_open, false)
         |> assign(:evidence_page, 0)
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
    {:noreply, select(socket, params["exception"] || default_selected(socket))}
  end

  # Selecting a different exception starts its evidence over: page 1, overlay
  # shut. The overlay's own Esc never comes through here, so closing the reader
  # leaves the selection exactly where it was.
  defp select(socket, id) do
    socket
    |> assign(:selected_id, id)
    |> assign(:evidence_page, 0)
    |> assign(:evidence_open, false)
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
    |> assign(:groups, groups(queue))
    |> assign(:progress, progress(queue))
    |> assign(:stats, Register.stats(workings.summary))
    |> assign(:itc, workings.itc)
  end

  # Two kinds of work, not one pile. A decision is somebody's judgement about
  # what gets filed; a 2B-only line is a bill nobody sent, which no judgement
  # here can produce. Merging them is what made "0 of 12 resolved" a number over
  # a queue of which nine were the client's job.
  @group_order [
    %{
      key: :decisions,
      kind: :books,
      title: "Decisions",
      blurb:
        "Your call. Each is one tap from its scanned bill — decide it, and it stays here marked done."
    },
    %{
      key: :collection,
      kind: :gstr2b,
      title: "Bills to collect",
      blurb:
        "The portal reported these supplies and the books have no document for them. There is no scan to open — the next move is a request to the client."
    }
  ]

  defp groups(queue) do
    Enum.flat_map(@group_order, fn group ->
      case Enum.filter(queue, &(&1.kind == group.kind)) do
        [] ->
          []

        items ->
          [
            Map.merge(group, %{
              items: items,
              count: length(items),
              tax_paise: items |> Enum.map(& &1.tax_paise) |> Enum.sum()
            })
          ]
      end
    end)
  end

  defp build_queue(workings, month) do
    asked_at = last_ask_at(month)
    gaps = evidence_gaps(month)

    books_items =
      (workings.baseline["needs_human"] || []) ++
        (workings.baseline["in_books_not_2b"] || [])

    books_queue = Enum.map(books_items, &exception_item(&1, workings, month, gaps))

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

  defp exception_item(entry, workings, month, gaps) do
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
      evidence_gap: evidence_gap(books, gaps),
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
      # A 2B-only line never had a bill to render; its emptiness is the finding.
      evidence_gap: nil,
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

  # Progress reads decisions alone. Counting the collection queue in the
  # denominator reported a reviewer as 0/12 done when nine of the twelve were
  # never his to move.
  defp progress(queue) do
    decisions = Enum.filter(queue, &(&1.kind == :books))
    %{done: Enum.count(decisions, & &1.resolved), total: length(decisions)}
  end

  defp image_urls(books, month) do
    Enum.map(books["images"] || [], fn path ->
      ~p"/gst/#{month.client_id}/#{month.period}/evidence/#{Path.basename(path)}"
    end)
  end

  # A dump whose pages could not be rasterized leaves its invoices with no
  # images — on the page, indistinguishable from a bill that never arrived,
  # which is the one case that has no next step. Extraction namespaces the
  # dump id into every invoice id (`d12_page_03`), so the failed dumps can name
  # their own rows and offer the original file instead.
  defp evidence_gaps(month) do
    month.org_id
    |> Dumps.evidence_gaps(month.client_id, month.period, "purchase")
    |> Map.new(fn %{"dump_id" => dump_id, "source" => source} ->
      {dump_id,
       %{
         source: source,
         original_url: ~p"/gst/#{month.client_id}/#{month.period}/original/#{dump_id}/0"
       }}
    end)
  end

  defp evidence_gap(books, gaps) do
    images = books["images"] || []

    case Regex.run(~r/\Ad(\d+)_/, to_string(books["id"])) do
      [_match, dump_id] when images == [] -> Map.get(gaps, String.to_integer(dump_id))
      _no_dump_prefix -> nil
    end
  end

  @impl true
  def handle_event("select", %{"id" => id}, socket) do
    {:noreply,
     push_patch(socket,
       to:
         ~p"/gst/#{socket.assigns.month.client_id}/#{socket.assigns.month.period}/exceptions?exception=#{id}"
     )}
  end

  # The reader is read-only, so it stays open on a signed-off month and never
  # touches the selection: Esc closes the overlay and nothing else.
  def handle_event("open-evidence", _params, socket),
    do: {:noreply, assign(socket, :evidence_open, true)}

  def handle_event("close-evidence", _params, socket),
    do: {:noreply, assign(socket, :evidence_open, false)}

  def handle_event("evidence-page", %{"page" => page}, socket) do
    pages = length(selected_images(socket))

    case Integer.parse(to_string(page)) do
      {n, ""} when n >= 0 and n < pages -> {:noreply, assign(socket, :evidence_page, n)}
      _out_of_range -> {:noreply, socket}
    end
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
        {:noreply, socket |> assign_workings(result.month, result.workings) |> select(id)}

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
        {:noreply, socket |> assign_workings(result.month, result.workings) |> select(id)}

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
     |> select(draft.item_id)
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

  defp selected_images(socket) do
    case find_item(socket, socket.assigns.selected_id) do
      nil -> []
      item -> item.images
    end
  end

  defp blank?(v), do: is_nil(v) or String.trim(to_string(v)) == ""

  # A snapshot frozen before the money split existed reads ₹0 for both subsets,
  # which is indistinguishable from a real zero. Say the counts and say the
  # breakdown is unavailable rather than asserting a confident ₹0.
  defp open_money_clause(%{open_money_split_known?: false} = stats) do
    "#{stats.need_decision} #{pluralise(stats.need_decision, "decision")} · " <>
      "#{stats.awaiting_bills} #{pluralise(stats.awaiting_bills, "bill")} to collect " <>
      "(legacy snapshot: counts only — monetary breakdown unavailable)"
  end

  defp open_money_clause(stats) do
    "#{stats.need_decision} #{pluralise(stats.need_decision, "decision")} · " <>
      "#{money(stats.decision_tax_paise)} · " <>
      "#{stats.awaiting_bills} #{pluralise(stats.awaiting_bills, "bill")} to collect · " <>
      "#{money(stats.awaiting_bills_tax_paise)}"
  end

  defp money(paise), do: Nila.Formatters.format_money(paise || 0)

  defp pluralise(1, noun), do: noun
  defp pluralise(_count, noun), do: noun <> "s"

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
      <div id="gst-exceptions" class="space-y-section mx-auto max-w-7xl">
        <div class="flex items-center justify-between">
          <%!-- "Each is one tap from its scanned bill" is false for every 2B-only
                line, which has no bill by construction. The groups say it per
                kind; the header states the track. --%>
          <.page_header eyebrow="GST · Exceptions" title={"#{@month.client.name} · #{@month.period}"}>
            {open_money_clause(@stats)}
          </.page_header>
          <div class="flex shrink-0 items-center gap-4">
            <span
              :if={@progress.total > 0}
              id="gst-exceptions-progress"
              class="text-ink-subtle text-ui"
            >
              {@progress.done} of {@progress.total} {pluralise(@progress.total, "decision")} made
            </span>
            <.link
              navigate={~p"/gst/#{@month.client_id}/#{@month.period}"}
              class="hover:text-ink text-ink-subtle text-ui"
            >← Full register</.link>
          </div>
        </div>

        <div
          :if={@progress.total > 0 and @progress.done == @progress.total}
          id="gst-exceptions-cleared"
          class="bg-success/[0.04] border-success/40 rounded-box flex items-center gap-2 border px-4 py-3"
        >
          <.icon name="hero-check-circle" class="text-success size-5 shrink-0" />
          <p class="text-base-content text-ui">
            Every exception is resolved — the register is review-ready. Anything look wrong? Undo it below.
          </p>
        </div>

        <Itc.itc_panel itc={@itc} signed_off={@signed_off} />
        <Surface.exception_surface
          queue={@queue}
          groups={@groups}
          selected_id={@selected_id}
          selected={@selected}
          signed_off={@signed_off}
          correcting={@correcting}
          evidence_page={@evidence_page}
        />
      </div>

      <.evidence_overlay
        :if={(@evidence_open and @selected) && @selected.images != []}
        id="gst-evidence-overlay"
        images={@selected.images}
        page={@evidence_page}
        title={"#{@selected.invoice_number || "—"} · #{@selected.vendor}"}
        on_close="close-evidence"
        on_page="evidence-page"
      />

      <Modal.missing_bill_modal draft={@draft} />
    </Layouts.app>
    """
  end
end
