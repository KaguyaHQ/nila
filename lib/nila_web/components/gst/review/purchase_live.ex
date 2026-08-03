defmodule NilaWeb.Components.Gst.Review.PurchaseLive do
  use NilaWeb, :live_component

  alias Nila.Gst.Chase
  alias Nila.Gst.Intake.Dumps
  alias Nila.Gst.Purchase.{Review, Resolutions}
  alias NilaWeb.Components.Gst.Exceptions.{Modal, Surface}

  @impl true
  def update(assigns, socket) do
    month = assigns.month
    workings = assigns.workings

    review =
      Review.project(workings,
        month: month,
        asked_at: last_ask_at(month),
        evidence_gaps: evidence_gaps(month)
      )

    route =
      review
      |> Review.route_state(assigns.route.item, assigns.route.scope)
      |> Map.put(:focus, assigns.route[:focus])

    socket =
      socket
      |> assign(assigns)
      |> assign(:month, month)
      |> assign(:workings, workings)
      |> assign(:review, review)
      |> assign(:route, route)
      |> assign(:queue, Review.items(review, route.scope))
      |> assign(:groups, Review.sections(review, route.scope))
      |> assign(:selected_id, route.item)
      |> assign(:correcting, socket.assigns[:correcting])
      |> assign(:draft, socket.assigns[:draft])
      |> assign(:evidence_open, socket.assigns[:evidence_open] || false)
      |> assign(:evidence_page, socket.assigns[:evidence_page] || 0)

    {:ok, socket}
  end

  @impl true
  def handle_event("done", _params, socket),
    do: {:noreply, push_patch(socket, to: month_path(socket))}

  def handle_event("scope", %{"scope" => scope}, socket) when scope in ~w(needs_you all) do
    item = Review.lookup(socket.assigns.review.all, socket.assigns.selected_id)

    selected =
      Review.lookup(
        Review.items(socket.assigns.review, String.to_existing_atom(scope)),
        item && item.id
      )

    selected =
      selected || List.first(Review.items(socket.assigns.review, String.to_existing_atom(scope)))

    {:noreply, push_patch(socket, to: review_path(socket, selected && selected.id, scope))}
  end

  def handle_event("select", %{"id" => id}, socket),
    do: {:noreply, push_patch(socket, to: review_path(socket, id, socket.assigns.route.scope))}

  def handle_event("next", _params, socket) do
    case Review.next(
           socket.assigns.review,
           socket.assigns.route.scope,
           socket.assigns.selected_id
         ) do
      nil ->
        {:noreply, socket}

      item ->
        {:noreply,
         push_patch(socket, to: review_path(socket, item.id, socket.assigns.route.scope))}
    end
  end

  def handle_event("open-evidence", _params, socket),
    do: {:noreply, assign(socket, :evidence_open, true)}

  def handle_event("close-evidence", _params, socket),
    do: {:noreply, assign(socket, :evidence_open, false)}

  def handle_event("evidence-page", %{"page" => page}, socket) do
    pages = length(selected(socket).images)

    case Integer.parse(to_string(page)) do
      {n, ""} when n >= 0 and n < pages -> {:noreply, assign(socket, :evidence_page, n)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event(verb, _params, %{assigns: %{signed_off: true}} = socket)
      when verb in ~w(confirm_pair reject_pair reject_all accept_unmatched dismiss_2b start_correct save_correct undo challenge block_itc allow_itc reopen_block attest_documents reopen_attestation) do
    {:noreply, put_flash(socket, :error, signed_off_message(socket))}
  end

  def handle_event("challenge", %{"id" => id}, socket) do
    item = find_item(socket, id)
    candidate = List.first(item.candidates)

    attrs = %{
      "verb" => "challenge_pair",
      "books_id" => candidate.books_id,
      "gstr2b_ref" => candidate.ref,
      "payload" => Review.pair_payload(item, candidate.books_id, candidate.ref, "challenge_pair")
    }

    record(socket, attrs, item.id)
  end

  def handle_event("confirm_pair", %{"id" => id} = params, socket) do
    item = find_item(socket, id)

    candidate =
      Enum.find(
        item.candidates,
        &(&1.ref == (params["ref"] || List.first(item.candidates).ref) and
            (&1.books_id == id or id == item.id))
      ) || List.first(item.candidates)

    attrs = %{
      "verb" => "confirm_pair",
      "books_id" => candidate.books_id,
      "gstr2b_ref" => candidate.ref,
      "payload" => Review.pair_payload(item, candidate.books_id, candidate.ref, "confirm_pair")
    }

    record(socket, attrs, item.id)
  end

  def handle_event("reject_pair", %{"id" => id}, socket) do
    item = find_item(socket, id)
    candidate = Enum.find(item.candidates, &(&1.books_id == id)) || List.first(item.candidates)

    attrs = %{
      "verb" => "reject_pair",
      "books_id" => candidate.books_id,
      "gstr2b_ref" => candidate.ref,
      "payload" => Review.pair_payload(item, candidate.books_id, candidate.ref, "reject_pair")
    }

    record(socket, attrs, item.id)
  end

  def handle_event("reject_all", %{"id" => id}, socket) do
    item = find_item(socket, id)

    attrs =
      Enum.map(item.candidates, fn candidate ->
        %{
          "verb" => "reject_pair",
          "books_id" => candidate.books_id,
          "gstr2b_ref" => candidate.ref,
          "payload" => Review.pair_payload(item, candidate.books_id, candidate.ref, "reject_pair")
        }
      end)
      |> Enum.uniq()

    record_many(socket, attrs, item.id)
  end

  def handle_event("accept_unmatched", %{"id" => id, "reason" => reason}, socket)
      when reason in ~w(await_2b not_claimable) do
    item = find_item(socket, id)

    attrs =
      Enum.map(
        item.member_ids,
        &%{"verb" => "accept_unmatched", "books_id" => &1, "payload" => %{"reason" => reason}}
      )

    record_many(socket, attrs, item.id)
  end

  def handle_event("accept_unmatched", _, socket), do: {:noreply, socket}

  def handle_event("dismiss_2b", %{"id" => id}, socket) do
    item = find_item(socket, id)
    record(socket, %{"verb" => "dismiss_2b", "gstr2b_ref" => item.gstr2b_ref}, item.id)
  end

  def handle_event("start_correct", %{"id" => id}, socket) do
    item = find_item(socket, id)
    books = Enum.find(item.books_members, &(&1["id"] == id)) || item.books

    {:noreply,
     assign(socket, :correcting, %{id: books["id"], value: books["invoice_number"] || ""})}
  end

  def handle_event("cancel_correct", _, socket), do: {:noreply, assign(socket, :correcting, nil)}

  def handle_event("save_correct", %{"id" => id, "value" => value}, socket) do
    item = find_item(socket, id)
    books = Enum.find(item.books_members, &(&1["id"] == id)) || item.books
    from = books["invoice_number"]

    if blank?(value) or value == from do
      {:noreply, assign(socket, :correcting, nil)}
    else
      record(
        socket,
        %{
          "verb" => "correct_field",
          "books_id" => books["id"],
          "payload" => %{"field" => "invoice_number", "from" => from, "to" => String.trim(value)}
        },
        item.id,
        &assign(&1, :correcting, nil)
      )
    end
  end

  def handle_event("undo", %{"id" => id}, socket) do
    item = find_item(socket, id)

    attrs =
      if item.kind == :books do
        Enum.map(item.member_ids, &%{"verb" => "reopen", "books_id" => &1})
      else
        [%{"verb" => "reopen", "gstr2b_ref" => item.gstr2b_ref}]
      end

    record_many(socket, attrs, item.id)
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

    {:noreply, assign(socket, :draft, %{body: body, item_id: item.id})}
  end

  def handle_event("close-ask", _, socket), do: {:noreply, assign(socket, :draft, nil)}

  def handle_event("mark-ask-sent", _, socket) do
    %{month: month, draft: draft, current_scope: scope} = socket.assigns

    {:ok, _} =
      Chase.record_ask(
        %{org_id: month.org_id, client_id: month.client_id, sent_by_id: scope.user.id},
        %{kind: "missing_bills", period: month.period, body: draft.body, channel: "manual"}
      )

    send(self(), {:purchase_review_refresh, draft.item_id, month, socket.assigns.workings})
    {:noreply, socket |> assign(:draft, nil) |> put_flash(:info, "Ask logged.")}
  end

  def handle_event(verb, %{"block-id" => block_id}, socket)
      when verb in ["block_itc", "allow_itc"],
      do: refresh_only(socket, %{"verb" => verb, "payload" => %{"block_id" => block_id}})

  def handle_event("reopen_block", %{"block-id" => id}, socket),
    do: refresh_only(socket, %{"verb" => "reopen", "payload" => %{"block_id" => id}})

  def handle_event("attest_documents", %{"answer" => answer}, socket)
      when answer in ~w(held not_held unknown),
      do:
        refresh_only(socket, %{
          "verb" => "attest_documents",
          "payload" => %{
            "target" => socket.assigns.workings.document_attestation.target,
            "answer" => answer
          }
        })

  def handle_event("reopen_attestation", _, socket),
    do:
      refresh_only(socket, %{
        "verb" => "reopen",
        "payload" => %{"target" => socket.assigns.workings.document_attestation.target}
      })

  defp record(socket, attrs, id, after_fun \\ & &1),
    do: record_many(socket, [attrs], id, after_fun)

  defp record_many(socket, attrs, id, after_fun \\ & &1) do
    case Resolutions.record_many_and_refresh(
           socket.assigns.month,
           attrs,
           socket.assigns.current_scope.user.id
         ) do
      {:ok, result} ->
        send(self(), {:purchase_review_refresh, id, result.month, result.workings})
        {:noreply, after_fun.(socket)}

      {:error, :signed_off} ->
        {:noreply, put_flash(socket, :error, signed_off_message(socket))}
    end
  end

  defp refresh_only(socket, attrs), do: record(socket, attrs, socket.assigns.selected_id)

  defp selected(socket), do: find_item(socket, socket.assigns.selected_id)

  defp find_item(socket, id) do
    socket.assigns.review.all
    |> Review.lookup(id)
    |> Review.focus(socket.assigns.route.focus)
  end

  defp blank?(value), do: is_nil(value) or String.trim(to_string(value)) == ""

  defp last_ask_at(month) do
    case Chase.last_ask(month.org_id, month.client_id, month.period) do
      {:ok, ask} -> ask.inserted_at
      {:error, :not_found} -> nil
    end
  end

  defp evidence_gaps(month) do
    month.org_id
    |> Dumps.evidence_gaps(month.client_id, month.period, "purchase")
    |> Map.new(fn %{"dump_id" => id, "source" => source} ->
      {id,
       %{source: source, original_url: "/gst/#{month.client_id}/#{month.period}/original/#{id}/0"}}
    end)
  end

  defp signed_off_message(%{assigns: %{month: %{filed_at: filed}}}) when not is_nil(filed),
    do: "This return is filed. Challenge requires an amendment."

  defp signed_off_message(_),
    do: "Month is signed off — a senior must reopen it from the month page."

  defp month_path(socket),
    do: "/gst/#{socket.assigns.month.client_id}/#{socket.assigns.month.period}"

  defp review_path(socket, item, scope) do
    base = month_path(socket) <> "/review/purchase"
    query = URI.encode_query(%{"item" => item || "", "scope" => to_string(scope)})
    base <> "?" <> query
  end

  @impl true
  def render(assigns) do
    selected =
      assigns.review.all
      |> Review.lookup(assigns.selected_id)
      |> Review.focus(assigns.route.focus)

    next_item = Review.next(assigns.review, assigns.route.scope, assigns.selected_id)
    assigns = assign(assigns, selected: selected, next_item: next_item)

    ~H"""
    <div id="purchase-review-component">
      <.modal
        id="purchase-review"
        title="Purchase review"
        variant="workbench"
        close_label="Done"
        on_close="done"
        target={@myself}
        close_on_escape={is_nil(@correcting) and is_nil(@draft) and not @evidence_open}
      >
        <:header :let={title_id}>
          <div class="flex flex-wrap items-center gap-4">
            <h2 id={title_id} class="text-base-content text-body font-semibold">Purchase review</h2>
            <span id="purchase-review-progress" class="text-ink-subtle text-ui">
              {@review.progress.done} of {@review.progress.total} decisions · {@review.missing_count} bills to collect
            </span>
            <div id="purchase-review-scope" class="join">
              <button
                :for={{scope, label} <- [{:needs_you, "Needs you"}, {:all, "All"}]}
                type="button"
                phx-click="scope"
                phx-value-scope={scope}
                phx-target={@myself}
                class={["btn btn-sm join-item", @route.scope == scope && "btn-active"]}
              >{label}</button>
            </div>
            <.button
              id="purchase-review-next"
              variant="outline"
              size="sm"
              phx-click="next"
              phx-target={@myself}
              disabled={is_nil(@next_item)}
            >Next <.icon name="hero-arrow-right-mini" class="size-4" /></.button>
          </div>
        </:header>

        <Surface.exception_surface
          queue={@queue}
          groups={@groups}
          selected_id={@selected_id}
          selected={@selected}
          signed_off={@signed_off}
          correcting={@correcting}
          evidence_page={@evidence_page}
          target={@myself}
        />
      </.modal>

      <.evidence_overlay
        :if={(@evidence_open and @selected) && @selected.images != []}
        id="gst-evidence-overlay"
        images={@selected.images}
        page={@evidence_page}
        title={"#{@selected.invoice_number || "—"} · #{@selected.vendor}"}
        on_close="close-evidence"
        on_page="evidence-page"
        target={@myself}
      />
      <Modal.missing_bill_modal draft={@draft} target={@myself} />
    </div>
    """
  end
end
