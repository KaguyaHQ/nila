defmodule NilaWeb.Components.Gst.Review.SalesLive do
  use NilaWeb, :live_component

  alias Nila.Gst.Sales.Invoice.Validation, as: InvoiceValidation
  alias Nila.Gst.Sales.Invoice
  alias Nila.Gst.Proposals
  alias Nila.Gst.Sales.{Review, Workings}
  alias Nila.Gst.Sales.Review.Resolutions
  alias Nila.Gst.Sales.Review.Values
  alias Nila.TallyMappings
  alias NilaWeb.Components.Gst.Month.Evidence

  @write_events ~w(resolve-invoice-issue undo start_correct save_correct save-tally-posting)

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
    tally_posting = tally_posting(assigns, selected_invoice)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:locked, not is_nil(assigns.month.filed_at))
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
     |> assign(:tally_posting, tally_posting)
     |> assign(:evidence_open, evidence_open)
     |> assign(:evidence_page, evidence_page)}
  end

  @impl true
  def handle_event("done", _params, socket) do
    case socket.assigns.route[:return_to] do
      return_to when is_binary(return_to) ->
        {:noreply, push_navigate(socket, to: return_to)}

      _month ->
        {:noreply, push_patch(socket, to: month_path(socket))}
    end
  end

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

  def handle_event(event, _params, %{assigns: %{locked: true}} = socket)
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
    correcting = %{field: field, value: to_string(Invoice.field_value(invoice, field))}

    {:noreply,
     assign(socket,
       correcting: correcting,
       correction_form: correction_form(correcting)
     )}
  end

  def handle_event("cancel_correct", _params, socket),
    do: {:noreply, assign(socket, correcting: nil, correction_form: nil)}

  def handle_event(
        "save-tally-posting",
        %{"tally_posting" => posting},
        %{assigns: %{tally_company: %{id: company_id}, selected_invoice: invoice}} = socket
      ) do
    org_id = socket.assigns.current_scope.current_org.id

    profile_attrs =
      posting
      |> Map.take(
        ~w(sales_ledger_identity cgst_ledger_identity sgst_ledger_identity igst_ledger_identity)
      )

    with {:ok, _saved} <-
           TallyMappings.save_sales_posting(
             org_id,
             company_id,
             party_identity(invoice),
             posting["party_ledger_identity"],
             profile_attrs
           ) do
      {:noreply,
       socket
       |> assign(:tally_posting, tally_posting(socket.assigns, invoice))
       |> put_flash(:info, "Tally posting saved.")}
    else
      {:error, :filed} ->
        {:noreply, put_flash(socket, :error, locked_message(socket))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Tally posting could not be saved.")}
    end
  end

  def handle_event("save-tally-posting", _params, socket), do: {:noreply, socket}

  def handle_event(
        "save_correct",
        %{"correction" => %{"field" => field, "value" => value}},
        socket
      ) do
    invoice = socket.assigns.selected_invoice
    from = Invoice.field_value(invoice, field)
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
          "to" => Invoice.coerce_correction(field, value)
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

      {:error, :filed} ->
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
      Values.for_invoice(socket.assigns.selected_invoice, socket.assigns.workings),
      InvoiceValidation.checks(socket.assigns.selected_invoice)
    )
    |> Proposals.freeze()
  end

  defp correction_form(nil), do: nil

  defp correction_form(correcting) do
    to_form(%{"field" => correcting.field, "value" => correcting.value}, as: :correction)
  end

  defp tally_posting(%{tally_company: nil}, _invoice), do: nil
  defp tally_posting(_assigns, nil), do: nil

  defp tally_posting(assigns, invoice) do
    org_id = assigns.current_scope.current_org.id
    company = assigns.tally_company
    choices = TallyMappings.list_ledger_choices(org_id, company.id)
    party = resolved_party(org_id, company.id, invoice)
    profile = posting_profile(org_id, company.id)
    tax_heads = applicable_tax_heads(invoice)

    values = %{
      "party_ledger_identity" => party && party.ledger.identity,
      "sales_ledger_identity" =>
        profile_value(profile, :sales_ledger_identity) || default_identity(choices, "Sales"),
      "cgst_ledger_identity" =>
        profile_value(profile, :cgst_ledger_identity) ||
          resolved_tax_ledger_identity(org_id, company.id, :cgst),
      "sgst_ledger_identity" =>
        profile_value(profile, :sgst_ledger_identity) ||
          resolved_tax_ledger_identity(org_id, company.id, :sgst),
      "igst_ledger_identity" =>
        profile_value(profile, :igst_ledger_identity) ||
          resolved_tax_ledger_identity(org_id, company.id, :igst)
    }

    %{
      company: company,
      party_choices: ledger_options(choices, "Sundry Debtors"),
      sales_choices: ledger_options(choices, "Sales Accounts"),
      tax_choices: ledger_options(choices, "Duties & Taxes"),
      form: to_form(values, as: :tally_posting),
      tax_heads: tax_heads
    }
  end

  defp resolved_party(org_id, company_id, invoice) do
    case TallyMappings.resolve_party(org_id, company_id, party_identity(invoice)) do
      {:ok, match} -> match
      {:error, _reason} -> nil
    end
  end

  defp resolved_tax_ledger_identity(org_id, company_id, head) do
    case TallyMappings.resolve_tax_ledger(org_id, company_id, head) do
      {:ok, %{ledger: ledger}} -> ledger.identity
      {:error, _reason} -> nil
    end
  end

  defp posting_profile(org_id, company_id) do
    case TallyMappings.get_posting_profile(org_id, company_id) do
      {:ok, profile} -> profile
      {:error, :not_found} -> nil
    end
  end

  defp party_identity(invoice) do
    %{
      gstin: invoice["buyer_gstin"],
      name: invoice["buyer_name"],
      source_key: invoice["id"] || invoice["invoice_number"]
    }
  end

  defp applicable_tax_heads(invoice) do
    lines = invoice["line_items"] || []

    ~w(cgst sgst igst)
    |> Enum.filter(fn head ->
      Enum.any?(lines, fn line ->
        positive?(line["#{head}_amount"]) or positive?(line["#{head}_rate"])
      end)
    end)
    |> MapSet.new()
  end

  defp positive?(value) when is_number(value), do: value > 0

  defp positive?(value) when is_binary(value) do
    case Float.parse(String.replace(value, ",", "")) do
      {number, ""} -> number > 0
      _ -> false
    end
  end

  defp positive?(_value), do: false

  defp profile_value(nil, _field), do: nil
  defp profile_value(profile, field), do: Map.get(profile, field)

  defp default_identity(choices, canonical_name) do
    canonical = String.downcase(canonical_name)

    case Enum.filter(choices, &(String.downcase(String.trim(&1.name)) == canonical)) do
      [choice] -> choice.identity
      _ -> nil
    end
  end

  defp ledger_options(choices, parent) do
    matching = Enum.filter(choices, &(normalized_parent(&1) == String.downcase(parent)))
    choices = if matching == [], do: choices, else: matching
    Enum.map(choices, &{&1.name, &1.identity})
  end

  defp normalized_parent(%{data: data}) when is_map(data) do
    data
    |> Map.get("parent", "")
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp image_urls(%{"image" => basename}, month) when is_binary(basename),
    do: ["/gstr1/#{month.client_id}/#{month.period}/evidence/#{basename}"]

  defp image_urls(_invoice, _month), do: []

  defp locked_message(_socket), do: "Filed returns require an amendment."

  # Current sales workspaces always pass an explicit `return_to`. Keep the old
  # fallback while the frozen month UI remains available for legacy tests and
  # purchase/3B work; it is not linked from the product navigation.
  defp month_path(socket),
    do: "/gst/#{socket.assigns.month.client_id}/#{socket.assigns.month.period}?track=sales"

  defp review_path(socket, item, scope) do
    params =
      %{
        "item" => (item && item.source_id) || "",
        "scope" => to_string(scope),
        "tally_company_id" => socket.assigns.route[:tally_company_id],
        "return_to" => socket.assigns.route[:return_to]
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

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

            <.segmented_control
              id="sales-review-scope"
              items={[{:needs_you, "Needs you"}, {:all, "All"}]}
              selected={@route.scope}
              on_change="scope"
              value_name="scope"
              target={@myself}
            />
          </div>
        </:header>

        <div class="gap-block grid h-full min-h-0 lg:grid-cols-[18rem_minmax(0,1fr)] lg:grid-rows-[minmax(0,1fr)]">
          <aside id="sales-review-rail" class="border-rule min-h-0 overflow-y-auto border-r pr-4">
            <div class="space-y-related">
              <button
                :for={item <- @queue}
                type="button"
                id={"sales-review-rail-#{item.source_id}"}
                phx-click="select"
                phx-value-id={item.source_id}
                phx-target={@myself}
                class="border-rule nila-sales-review-item rounded-box w-full border p-3 text-left transition"
                data-selected={to_string(@selected_id == item.source_id)}
                aria-current={@selected_id == item.source_id && "true"}
              >
                <span
                  class="text-base-content text-ui block truncate font-mono"
                  title={item.invoice["invoice_number"] || "—"}
                >
                  {item.invoice["invoice_number"] || "—"}
                </span>

                <span
                  class="text-ink-subtle text-ui block truncate"
                  title={item.invoice["buyer_name"] || item.invoice["buyer_gstin"] || "Unknown buyer"}
                >
                  {item.invoice["buyer_name"] || item.invoice["buyer_gstin"] || "Unknown buyer"}
                </span>
                <% {variant, label} = rail_state(item.state) %>
                <span class="mt-related flex items-center justify-between gap-2">
                  <.badge variant={variant}>{label}</.badge>

                  <span :if={item.open_actionable_targets != []} class="text-ink-subtle text-ui">
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
                class="border-rule mb-block rounded-box shrink-0 border p-3"
              >
                <p class="text-ink-muted text-ui">Nila found no invoice check requiring an answer.</p>
              </div>

              <Evidence.invoice_detail
                selected_invoice={@selected_invoice}
                issues_by_invoice={@issues_by_invoice}
                focused_issue={@route.focus}
                decisions={@decisions}
                review_navigation={@navigation}
                locked={@locked}
                flagged={@workings.flagged}
                correcting={@correcting}
                correction_form={@correction_form}
                tally_posting={@tally_posting}
                workings={@workings}
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
