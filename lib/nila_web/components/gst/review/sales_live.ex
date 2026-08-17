defmodule NilaWeb.Components.Gst.Review.SalesLive do
  use NilaWeb, :live_component

  alias Nila.Gst.Proposals
  alias Nila.Gst.Sales.{Gstr1, Review, Resolutions, Values, Workings}
  alias NilaWeb.Components.Gst.Month.Evidence

  @write_events ~w(resolve-invoice-issue undo start_correct save_correct)

  @impl true
  def update(assigns, socket) do
    workings = assigns.workings
    review = Review.build(workings)
    route = Map.put(assigns.route, :focus, assigns.route[:focus])
    selected_item = Review.lookup(review.all, route.item)
    selected_id = selected_item && selected_item.source_id
    same_item? = socket.assigns[:selected_id] == selected_id

    selected_invoice =
      selected_item &&
        Map.put(
          selected_item.invoice,
          "image_urls",
          image_urls(selected_item.invoice, assigns.month)
        )

    correcting = if same_item?, do: socket.assigns[:correcting], else: nil
    evidence_open = same_item? && (socket.assigns[:evidence_open] || false)
    evidence_page = if same_item?, do: socket.assigns[:evidence_page] || 0, else: 0

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:workings, workings)
     |> assign(:review, review)
     |> assign(:route, route)
     |> assign(:queue, Review.scope(review, route.scope))
     |> assign(:selected_item, selected_item)
     |> assign(:selected_id, selected_id)
     |> assign(:selected_invoice, selected_invoice)
     |> assign(:issues_by_invoice, Enum.group_by(workings.issues, & &1["source_id"]))
     |> assign(:decisions, assigns.decisions)
     |> assign(:correcting, correcting)
     |> assign(:correction_form, correction_form(correcting))
     |> assign(:evidence_open, evidence_open)
     |> assign(:evidence_page, evidence_page)}
  end

  @impl true
  def handle_event("done", _params, socket),
    do: {:noreply, push_patch(socket, to: month_path(socket))}

  def handle_event("scope", %{"scope" => scope}, socket) when scope in ~w(needs_you all) do
    selected =
      Review.lookup(Review.scope(socket.assigns.review, scope), socket.assigns.selected_id) ||
        List.first(Review.scope(socket.assigns.review, scope))

    {:noreply, push_patch(socket, to: review_path(socket, selected, scope))}
  end

  def handle_event("select", %{"id" => source_id}, socket) do
    case Review.lookup(socket.assigns.queue, source_id) do
      nil ->
        {:noreply, socket}

      item ->
        {:noreply, push_patch(socket, to: review_path(socket, item, socket.assigns.route.scope))}
    end
  end

  def handle_event("navigate-invoice-review", %{"direction" => direction}, socket)
      when direction in ~w(previous next) do
    adjacent =
      apply(Review, String.to_existing_atom(direction), [
        socket.assigns.review,
        socket.assigns.route.scope,
        socket.assigns.selected_id
      ])

    if adjacent do
      {:noreply,
       push_patch(socket,
         to: review_path(socket, adjacent, socket.assigns.route.scope),
         replace: true
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("open-evidence", _params, socket),
    do: {:noreply, assign(socket, :evidence_open, true)}

  def handle_event("close-evidence", _params, socket),
    do: {:noreply, assign(socket, :evidence_open, false)}

  def handle_event("evidence-page", %{"page" => page}, socket) do
    count = length(socket.assigns.selected_invoice["image_urls"])

    case Integer.parse(to_string(page)) do
      {number, ""} when number >= 0 and number < count ->
        {:noreply, assign(socket, :evidence_page, number)}

      _invalid ->
        {:noreply, socket}
    end
  end

  def handle_event(event, _params, %{assigns: %{signoff: %{} = _signoff}} = socket)
      when event in @write_events,
      do: {:noreply, put_flash(socket, :error, locked_message(socket))}

  def handle_event(
        "resolve-invoice-issue",
        %{"target" => target, "decision" => "use_extracted_lines"},
        socket
      ) do
    issue = find_issue(socket, target)

    if issue && not Workings.blocking?(issue) do
      payload =
        case shown_proposal(socket, issue) do
          nil -> %{"decision" => "use_extracted_lines"}
          frozen -> %{"decision" => "use_extracted_lines", "proposal" => frozen}
        end

      record(socket, %{"verb" => "confirm_issue", "target" => target, "payload" => payload})
    else
      {:noreply, socket}
    end
  end

  def handle_event("resolve-invoice-issue", _params, socket), do: {:noreply, socket}

  def handle_event("undo", %{"target" => target}, socket),
    do: record(socket, %{"verb" => "reopen", "target" => target})

  def handle_event("start_correct", %{"field" => field}, socket) do
    invoice = socket.assigns.selected_invoice
    correcting = %{field: field, value: to_string(Gstr1.field_value(invoice, field))}

    {:noreply,
     assign(socket,
       correcting: correcting,
       correction_form: correction_form(correcting)
     )}
  end

  def handle_event("cancel_correct", _params, socket),
    do: {:noreply, assign(socket, correcting: nil, correction_form: nil)}

  def handle_event(
        "save_correct",
        %{"correction" => %{"field" => field, "value" => value}},
        socket
      ) do
    invoice = socket.assigns.selected_invoice
    from = Gstr1.field_value(invoice, field)
    value = String.trim(value)

    if value == "" or value == to_string(from) do
      {:noreply, assign(socket, correcting: nil, correction_form: nil)}
    else
      record(socket, %{
        "verb" => "correct_field",
        "target" => invoice["id"] || invoice["pristine_inum"],
        "payload" => %{
          "field" => field,
          "from" => from,
          "to" => Gstr1.coerce_correction(field, value)
        }
      })
    end
  end

  defp record(socket, attrs) do
    case Resolutions.record(
           socket.assigns.month,
           attrs,
           socket.assigns.current_scope.user.id
         ) do
      {:ok, _resolution} ->
        workings = Resolutions.workings(socket.assigns.month)

        send(
          self(),
          {:sales_review_refresh, socket.assigns.month, workings,
           %{
             item: socket.assigns.selected_id,
             scope: socket.assigns.route.scope,
             focus: socket.assigns.route.focus,
             action: attrs
           }}
        )

        {:noreply, assign(socket, correcting: nil, correction_form: nil)}

      {:error, :signed_off} ->
        {:noreply, put_flash(socket, :error, locked_message(socket))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "That invoice action could not be recorded.")}
    end
  end

  defp find_issue(socket, target) do
    Enum.find(socket.assigns.selected_item.issues, &(Workings.issue_key(&1) == target))
  end

  defp shown_proposal(socket, issue) do
    issue
    |> Proposals.for_issue(
      Values.for_invoice(socket.assigns.selected_invoice, socket.assigns.workings.derived),
      Gstr1.invoice_checks(socket.assigns.selected_invoice)
    )
    |> Proposals.freeze()
  end

  defp correction_form(nil), do: nil

  defp correction_form(correcting) do
    to_form(%{"field" => correcting.field, "value" => correcting.value}, as: :correction)
  end

  defp image_urls(%{"image" => basename}, month) when is_binary(basename),
    do: ["/gstr1/#{month.client_id}/#{month.period}/evidence/#{basename}"]

  defp image_urls(_invoice, _month), do: []

  defp locked_message(%{assigns: %{month: %{filed_at: filed_at}}}) when not is_nil(filed_at),
    do: "Filed returns require an amendment."

  defp locked_message(_socket), do: "Reopen GSTR-1 approval first."

  defp month_path(socket),
    do: "/gst/#{socket.assigns.month.client_id}/#{socket.assigns.month.period}?track=sales"

  defp review_path(socket, item, scope) do
    params = %{
      "item" => (item && item.source_id) || "",
      "scope" => to_string(scope)
    }

    "/gst/#{socket.assigns.month.client_id}/#{socket.assigns.month.period}/review/sales?" <>
      URI.encode_query(params)
  end

  defp rail_state(:needs_you), do: {"warning", "Needs you"}
  defp rail_state(:settled), do: {"success", "Resolved"}
  defp rail_state(:unreviewed), do: {"neutral", "No open checks"}

  @impl true
  def render(assigns) do
    previous =
      assigns.selected_id &&
        Review.previous(assigns.review, assigns.route.scope, assigns.selected_id)

    next_item =
      assigns.selected_id && Review.next(assigns.review, assigns.route.scope, assigns.selected_id)

    navigation = %{
      previous: previous && previous.source_id,
      next: next_item && next_item.source_id
    }

    assigns = assign(assigns, navigation: navigation)

    ~H"""
    <div id="sales-review-component">
      <.modal
        id="sales-review"
        title="Sales review"
        variant="workbench"
        close_label="Done"
        on_close="done"
        target={@myself}
        close_on_escape={is_nil(@correcting) and not @evidence_open}
      >
        <:header :let={title_id}>
          <div class="flex flex-wrap items-center gap-4">
            <h2 id={title_id} class="text-base-content text-body font-semibold">Sales review</h2>
            <span id="sales-review-progress" class="text-ink-subtle text-ui">
              {@review.progress.completed} of {@review.progress.total} checks complete
            </span>
            <span id="sales-review-month-checks" class="text-ink-subtle text-ui">
              {@review.month_issue_count} month checks remain on the month working paper
            </span>
            <div id="sales-review-scope" class="join">
              <button
                :for={{scope, label} <- [{:needs_you, "Needs you"}, {:all, "All"}]}
                type="button"
                phx-click="scope"
                phx-value-scope={scope}
                phx-target={@myself}
                class={["btn btn-sm join-item", @route.scope == scope && "btn-active"]}
              >{label}</button>
            </div>
          </div>
        </:header>

        <div class="gap-block grid h-full min-h-0 lg:grid-cols-[18rem_minmax(0,1fr)] lg:grid-rows-[minmax(0,1fr)]">
          <aside id="sales-review-rail" class="border-base-300 min-h-0 overflow-y-auto border-r pr-4">
            <div class="space-y-related">
              <button
                :for={item <- @queue}
                type="button"
                id={"sales-review-rail-#{item.source_id}"}
                phx-click="select"
                phx-value-id={item.source_id}
                phx-target={@myself}
                class={[
                  "border-base-300 hover:border-primary/40 rounded-box w-full border p-3 text-left transition",
                  @selected_id == item.source_id && "bg-primary/[0.04] border-primary"
                ]}
              >
                <span class="text-base-content text-ui block truncate font-mono">
                  {item.invoice["invoice_number"] || "—"}
                </span>
                <span class="text-ink-subtle text-meta block truncate">
                  {item.invoice["buyer_name"] || item.invoice["buyer_gstin"] || "Unknown buyer"}
                </span>
                <% {variant, label} = rail_state(item.state) %>
                <span class="mt-related flex items-center justify-between gap-2">
                  <.badge variant={variant}>{label}</.badge>
                  <span :if={item.open_actionable_targets != []} class="text-ink-subtle text-meta">
                    {length(item.open_actionable_targets)} open
                  </span>
                </span>
              </button>
              <p :if={@queue == []} id="sales-review-empty" class="text-ink-muted text-ui p-3">
                No invoices in this scope.
              </p>
            </div>
          </aside>

          <section id="sales-review-detail" class="flex min-h-0 flex-col overflow-hidden">
            <%= if @selected_item do %>
              <div
                :if={@selected_item.state == :unreviewed}
                id="sales-review-clean-treatment"
                class="border-base-300 mb-block rounded-box shrink-0 border p-3"
              >
                <p class="text-ink-muted text-ui">Nila found no invoice check requiring an answer.</p>
              </div>

              <Evidence.invoice_detail
                selected_invoice={@selected_invoice}
                issues_by_invoice={@issues_by_invoice}
                focused_issue={@route.focus}
                decisions={@decisions}
                review_navigation={@navigation}
                r1_signoff={@signoff}
                flagged={@workings.flagged}
                correcting={@correcting}
                correction_form={@correction_form}
                derived={@workings.derived}
                evidence_page={@evidence_page}
                target={@myself}
                event_target="#sales-review-component"
              />
            <% else %>
              <div class="text-body text-ink-muted flex h-full items-center justify-center">
                No active sales invoice has a filing treatment.
              </div>
            <% end %>
          </section>
        </div>
      </.modal>

      <.evidence_overlay
        :if={@evidence_open and @selected_invoice["image_urls"] != []}
        id="gstr1-evidence-overlay"
        images={@selected_invoice["image_urls"]}
        page={@evidence_page}
        title={@selected_invoice["invoice_number"] || "Invoice"}
        on_close="close-evidence"
        on_page="evidence-page"
        target={@myself}
      />
    </div>
    """
  end
end
