defmodule NilaWeb.Gst.PurchaseLive do
  use NilaWeb, :live_view
  alias Nila.Accounts.Policy
  import Ecto.Query, only: [from: 2]
  alias Nila.Repo
  alias Nila.Gst.Intake.{Dump, Dumps, DumpWorker, Preconditions, Progress}
  alias Nila.Gst.Purchase.Month
  alias Nila.Gst.Portal.Gstr2b
  alias Nila.Gst.Purchase.PortalImport
  alias Nila.Gst.Purchase.ItcDecisions
  alias NilaWeb.Gst.PurchaseWorkspace, as: Workspace

  @impl true
  def mount(%{"client_id" => client_id, "period" => period}, _, socket) do
    case Workspace.load(socket.assigns.current_scope, client_id, period) do
      {:ok, data} ->
        if connected?(socket) do
          Progress.subscribe(socket.assigns.current_scope.current_org.id)
          Gstr2b.subscribe(socket.assigns.current_scope.current_org.id)
        end

        {:ok,
         socket
         |> assign(data)
         |> assign(
           page_title: "Purchases",
           period: period,
           filter: "needs_review",
           q: "",
           error: nil,
           selected: MapSet.new(),
           claim_form: nil,
           intake_choices: %{},
           can_edit: Policy.can?(socket.assigns.current_scope, :edit_records),
           can_export: Policy.can?(socket.assigns.current_scope, :export)
         )
         |> inputs()}

      _ ->
        {:ok,
         socket
         |> put_flash(:error, "That client or month isn't available.")
         |> push_navigate(to: ~p"/clients")}
    end
  end

  @impl true
  def handle_params(_, _, %{assigns: assigns} = socket) when not is_map_key(assigns, :client),
    do: {:noreply, socket}

  def handle_params(params, _, socket) do
    filter = Workspace.normalize_filter(params["filter"])
    q = String.slice(params["q"] || "", 0, 200)
    {:noreply, socket |> assign(filter: filter, q: q) |> rows()}
  end

  @impl true
  def handle_event("select-itc", %{"id" => id}, socket) do
    item = Enum.find(socket.assigns.items, &(&1.id == id and &1.selectable?))

    if item && socket.assigns.can_edit && !socket.assigns.signed_off? do
      selected = socket.assigns.selected

      selected =
        if MapSet.member?(selected, item.case_id),
          do: MapSet.delete(selected, item.case_id),
          else: MapSet.put(selected, item.case_id)

      {:noreply, socket |> assign(selected: selected, claim_form: nil) |> rows()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("clear-selection", _, socket),
    do: {:noreply, socket |> assign(selected: MapSet.new(), claim_form: nil) |> rows()}

  def handle_event("exclude-itc", _, socket) do
    if socket.assigns.can_edit && !socket.assigns.signed_off? && socket.assigns.selected_count > 0 do
      {:noreply, assign(socket, error: nil, claim_form: to_form(%{"reason" => ""}, as: :claim))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel-claim", _, socket), do: {:noreply, assign(socket, claim_form: nil)}

  def handle_event("save-claim", %{"claim" => %{"reason" => reason}}, socket) do
    a = socket.assigns

    result =
      ItcDecisions.exclude(
        a.current_scope,
        a.client.id,
        a.period,
        MapSet.to_list(a.selected),
        reason
      )

    socket = assign(socket, claim_form: to_form(%{"reason" => reason}, as: :claim))
    claim_result(socket, result, "ITC decision saved. Other invoices remain unchanged.")
  end

  def handle_event("reopen-claim", _, socket) do
    a = socket.assigns

    result =
      ItcDecisions.reopen(a.current_scope, a.client.id, a.period, MapSet.to_list(a.selected))

    claim_result(socket, result, "Decision cleared. These invoices need an ITC review.")
  end

  def handle_event("reopen-case-claim", %{"id" => id}, socket) do
    a = socket.assigns
    result = ItcDecisions.reopen(a.current_scope, a.client.id, a.period, [id])
    claim_result(socket, result, "Decision cleared. This invoice needs an ITC review.")
  end

  def handle_event("import-excel", _, socket) do
    if socket.assigns.can_edit and not socket.assigns.signed_off?,
      do:
        {:noreply,
         push_navigate(socket,
           to:
             ~p"/gst/#{socket.assigns.client.id}/#{socket.assigns.period}/purchases/import-excel"
         )},
      else: {:noreply, socket}
  end

  def handle_event("search", %{"search" => %{"q" => q}}, socket) do
    {:noreply,
     push_patch(socket,
       to:
         Workspace.list_path(
           socket.assigns.client.id,
           socket.assigns.period,
           socket.assigns.filter,
           q
         )
     )}
  end

  def handle_event("use-2b", _, socket) do
    case PortalImport.import(
           socket.assigns.current_scope,
           socket.assigns.client.id,
           socket.assigns.period
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(error: nil)
         |> put_flash(:info, "GSTR-2B added. Preparing reconciliation.")
         |> reload()}

      {:error, reason} ->
        {:noreply,
         assign(
           socket,
           :error,
           if(is_binary(reason),
             do: reason,
             else: "Could not add GSTR-2B. Check access and fetch a statement for this month."
           )
         )}
    end
  end

  def handle_event("intake-choose", %{"id" => id, "answer" => answer}, socket)
      when answer in ~w(keep move discard) do
    {:noreply,
     assign(socket, :intake_choices, Map.put(socket.assigns.intake_choices, id, answer))}
  end

  def handle_event("intake-answer", %{"intake" => params}, socket) do
    case answer_intake(socket.assigns, params) do
      {:ok, dump} ->
        socket = socket |> assign(error: nil, intake_choices: %{}) |> reload()

        if dump.period != socket.assigns.period do
          {:noreply,
           push_navigate(socket,
             to: Workspace.list_path(dump.client_id, dump.period, "needs_review", "")
           )}
        else
          {:noreply, socket}
        end

      {:error, :reason_required} ->
        {:noreply, assign(socket, error: "Explain why this upload belongs in this month.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> reload()
         |> assign(
           error:
             if(is_binary(reason),
               do: reason,
               else: "This upload cannot be changed. Check your access and the month's status."
             )
         )}
    end
  end

  @impl true
  def handle_info({:gst_dump_progress, _, client_id, period, _, _}, socket) do
    if client_id == socket.assigns.client.id and period == socket.assigns.period,
      do: {:noreply, reload(socket)},
      else: {:noreply, socket}
  end

  def handle_info({:gst_statement_fetched, _}, socket), do: {:noreply, reload(socket)}
  def handle_info(_, socket), do: {:noreply, socket}

  defp reload(socket) do
    case Workspace.load(
           socket.assigns.current_scope,
           socket.assigns.client.id,
           socket.assigns.period
         ) do
      {:ok, data} -> socket |> assign(data) |> inputs() |> rows()
      _ -> socket
    end
  end

  defp claim_result(socket, {:ok, _}, message) do
    {:noreply,
     socket
     |> assign(selected: MapSet.new(), claim_form: nil, error: nil)
     |> put_flash(:info, message)
     |> reload()}
  end

  defp claim_result(socket, {:error, reason}, _) do
    message =
      case reason do
        :reason_required ->
          "Enter a reason (up to 1,000 characters)."

        :signed_off ->
          "This month is signed off or filed. Reopen it before changing ITC decisions."

        :already_allocated ->
          "A selected invoice is already included in a signed working. Reopen that working first."

        _ ->
          "Could not save these decisions. Check your access and select the invoices again."
      end

    {:noreply, socket |> reload() |> assign(error: message)}
  end

  defp inputs(socket) do
    a = socket.assigns
    dumps = Dumps.list(a.current_scope.current_org.id, a.client.id, a.period)
    purchase_dumps = Enum.filter(dumps, &(&1.kind == "purchase"))
    portal_dumps = Enum.filter(dumps, &(&1.kind == "gstr2b"))
    statement = Gstr2b.saved(a.current_scope.current_org.id, a.client.id, a.period)
    statement_dump = PortalImport.current_dump(statement, dumps)
    effective = Dumps.effective(a.current_scope.current_org.id, a.client.id, a.period, "gstr2b")

    assign(socket,
      dumps: Enum.filter(dumps, &(&1.kind in ~w(purchase gstr2b))),
      books_present:
        Enum.any?(purchase_dumps, &(&1.status == "extracted")) or
          Enum.any?(a.items, &(&1.kind == :books)),
      portal_present: effective != [],
      statement: statement,
      statement_needs_import:
        not is_nil(statement) and not is_nil(statement.fetched_at) and
          (is_nil(statement_dump) or statement_dump.status == "failed"),
      processing:
        Enum.any?(purchase_dumps ++ portal_dumps, &(&1.status in ~w(received extracting)))
    )
  end

  defp answer_intake(a, params) do
    target_period = if params["answer"] == "move", do: params["period"], else: a.period

    with true <- Policy.can?(a.current_scope, :edit_records),
         {dump_id, ""} when dump_id > 0 <- Integer.parse(to_string(params["id"])),
         {:ok, _} <- Gstr2b.month(target_period) do
      Repo.transact(fn ->
        # Match the worker's month-before-dump lock order, then recheck every boundary.
        Repo.all(
          from m in Month,
            where:
              m.org_id == ^a.current_scope.current_org.id and m.client_id == ^a.client.id and
                m.period in ^Enum.uniq([a.period, target_period]),
            order_by: [asc: m.period],
            lock: "FOR UPDATE"
        )

        dump =
          Repo.one(
            from d in Dump,
              where:
                d.id == ^dump_id and d.org_id == ^a.current_scope.current_org.id and
                  d.client_id == ^a.client.id and d.period == ^a.period,
              lock: "FOR UPDATE"
          )

        with %Dump{status: "needs_confirmation", kind: kind} = dump
             when kind in ~w(purchase gstr2b) <- dump,
             :open <- DumpWorker.wall_state(dump),
             :open <- DumpWorker.wall_state(%{dump | period: target_period}),
             {:ok, changed} <- apply_intake_answer(dump, params, a.current_scope.user.id) do
          if params["answer"] != "discard",
            do: %{dump_id: changed.id} |> DumpWorker.new() |> Oban.insert!()

          {:ok, changed}
        else
          state when state in [:held, :after_filing] ->
            {:error,
             "This month or the destination is signed off or filed. Reopen it before changing the upload."}

          {:error, _} = error ->
            error

          _ ->
            {:error, "This upload is no longer waiting for confirmation."}
        end
      end)
    else
      _ -> {:error, "Choose a valid month and check that you have permission to change uploads."}
    end
  end

  defp apply_intake_answer(dump, %{"answer" => "keep"} = params, user),
    do: Preconditions.keep(dump, params["reason"], user)

  defp apply_intake_answer(
         %Dump{kind: "purchase"} = dump,
         %{"answer" => "move", "period" => period},
         user
       ),
       do: Preconditions.move(dump, period, user)

  defp apply_intake_answer(%Dump{kind: "gstr2b"}, %{"answer" => "move"}, _user),
    do:
      {:error,
       "GSTR-2B belongs to its return month and cannot be moved. Fetch the statement for the correct month."}

  defp apply_intake_answer(dump, %{"answer" => "discard"}, user),
    do: Preconditions.discard(dump, user)

  defp apply_intake_answer(_, _, _), do: {:error, "Choose what to do with this upload."}

  defp intake_reason(dump) do
    finding = Dumps.precondition(dump) || %{}

    case finding["kind"] do
      "zero_overlap" ->
        "None of the purchase records matched GSTR-2B. Confirm these are the right inputs."

      "period_mismatch" ->
        "Most invoices are dated outside this month. Confirm when to include them."

      "cross_month_duplicate" ->
        "These invoices also appear in another month. Check for duplicate imports."

      _ ->
        "This upload needs confirmation before it can enter the working."
    end
  end

  defp next_step(%{signed_off?: true}),
    do: "Review the recorded purchase and ITC working for this month."

  defp next_step(%{processing: true}),
    do: "Preparing your records. Reconciliation results will appear here."

  defp next_step(%{books_present: false, portal_present: true}),
    do: "Select invoices to exclude from ITC, or import purchase Excel to compare with books."

  defp next_step(%{books_present: false}),
    do: "Import the client's purchase register, then compare it with GSTR-2B."

  defp next_step(%{statement_needs_import: true}),
    do: "GSTR-2B has been fetched. Start reconciliation against the client's purchase records."

  defp next_step(%{portal_present: false}),
    do: "Purchase records are ready. Fetch GSTR-2B to compare them with supplier records."

  defp next_step(_),
    do: "Review the differences below, then download the working for your senior."

  defp period_path(client_id, period, direction) do
    date = Date.from_iso8601!(period <> "-01")

    adjacent =
      if direction == :previous,
        do: Date.add(date, -1),
        else: date |> Date.end_of_month() |> Date.add(1)

    Workspace.list_path(client_id, Calendar.strftime(adjacent, "%Y-%m"), "needs_review", "")
  end

  defp rows(socket) do
    selectable_ids =
      socket.assigns.items |> Enum.filter(& &1.selectable?) |> MapSet.new(& &1.case_id)

    socket =
      assign(socket, :selected, MapSet.intersection(socket.assigns.selected, selectable_ids))

    a = socket.assigns
    filter = if !a.books_present and a.filter == "needs_review", do: "all", else: a.filter
    visible = Workspace.filter(a.items, filter, a.q)

    selected_items =
      Enum.filter(a.items, &MapSet.member?(a.selected, &1.case_id)) |> Enum.uniq_by(& &1.case_id)

    visible = Enum.map(visible, &Map.put(&1, :selected?, MapSet.member?(a.selected, &1.case_id)))

    tabs =
      Enum.map(Workspace.filters(), fn {key, label} ->
        %{
          id: "purchase-filter-#{key}",
          value: key,
          label: label,
          count: length(Workspace.filter(a.items, key, "")),
          patch: Workspace.list_path(a.client.id, a.period, key, a.q)
        }
      end)

    socket
    |> assign(
      visible_count: length(visible),
      hidden_selected_count:
        MapSet.size(MapSet.difference(a.selected, MapSet.new(visible, & &1.case_id))),
      selected_count: length(selected_items),
      selected_tax: Enum.sum(Enum.map(selected_items, & &1.claim_tax)),
      selected_invoices:
        Enum.map_join(selected_items, ", ", &(&1.invoice_number || "No invoice number")),
      can_reopen_claim:
        selected_items != [] and Enum.all?(selected_items, &(&1.claim_state == "not_claiming")),
      tabs: tabs,
      search_form: to_form(%{"q" => a.q}, as: :search)
    )
    |> stream(:purchase_items, visible, reset: true)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_client={@client}
      current_path={@current_path}
    >
      <div id="purchases-page" class="space-y-block mx-auto w-full max-w-[1400px]">
        <.page_header title="Purchases" eyebrow={@client.name <> " / " <> @period}>
          <:title_actions>
            <.button
              id="purchase-previous-month"
              variant="ghost"
              navigate={period_path(@client.id, @period, :previous)}
              aria-label="Previous month"
            ><.icon name="hero-chevron-left-mini" class="size-4" /></.button>
            <.button
              id="purchase-next-month"
              variant="ghost"
              navigate={period_path(@client.id, @period, :next)}
              aria-label="Next month"
            ><.icon name="hero-chevron-right-mini" class="size-4" /></.button>
          </:title_actions>
          <:actions>
            <.button
              id="purchase-import-excel"
              phx-click="import-excel"
              disabled={!@can_edit || @signed_off?}
            >Import purchase Excel</.button>
            <.button
              :if={@month && @can_export}
              id="purchase-workings-download"
              variant="soft"
              href={~p"/gst/#{@client.id}/#{@period}/purchases/workings.xlsx"}
            >Download working</.button>
          </:actions>
          <span id="purchase-next-step">{next_step(assigns)}</span>
        </.page_header>
        <div :if={@error} id="purchase-error">
          <.callout kind="error">{@error}</.callout>
        </div>
        <p :if={@signed_off?} id="purchase-frozen" class="text-ui">
          This month is signed off or filed. Review is read-only.
        </p>
        <div class="gap-block flex flex-wrap items-center justify-between">
          <p id="purchase-input-status" class="text-ui">
            Purchases: {if @books_present, do: "available", else: "not imported"} · GSTR-2B: {if @portal_present,
              do: "imported",
              else: "not imported"}
          </p>
          <div class="gap-related flex flex-wrap items-center">
            <.button
              variant="ghost"
              id="purchase-fetch-2b"
              navigate={~p"/gst/2b?#{%{client_id: @client.id, period: @period}}"}
            >{if @portal_present, do: "Refresh GSTR-2B", else: "Fetch GSTR-2B"}</.button>
            <.button
              :if={@statement_needs_import}
              variant="primary"
              id="purchase-use-2b"
              phx-click="use-2b"
              disabled={!@can_edit || @signed_off? || @processing}
              phx-disable-with="Adding…"
            >{if @portal_present, do: "Update reconciliation", else: "Start reconciliation"}</.button>
          </div>
        </div>
        <p :if={@processing} id="purchase-processing" role="status" class="text-ui">
          Preparing reconciliation. This list updates when processing finishes.
        </p>
        <.callout :for={dump <- Enum.filter(@dumps, &(&1.status == "failed"))} kind="error">
          {dump.source}: processing failed. {dump.error}
        </.callout>
        <section
          :for={dump <- Enum.filter(@dumps, &(&1.status in ~w(needs_confirmation held after_filing)))}
          id={"purchase-intake-#{dump.id}"}
          class="space-y-related"
        >
          <p class="text-ui font-medium">
            {dump.meta["original_name"] ||
              if(dump.kind == "gstr2b", do: "GSTR-2B", else: "Purchase upload")}
          </p>
          <p class="text-ui">
            {case dump.status do
              "held" ->
                "Waiting for a senior to reopen this signed month. This upload is not included in the working."

              "after_filing" ->
                "Arrived after filing. This upload is retained but is not included in the filed month."

              _ ->
                intake_reason(dump)
            end}
          </p>
          <div :if={dump.status == "needs_confirmation"} class="gap-related flex flex-wrap">
            <.button
              :for={
                {answer, label} <- [
                  {"keep", "Keep in this month"},
                  {"move", "Move to another month"},
                  {"discard", "Leave out this upload"}
                ]
              }
              :if={answer != "move" or dump.kind == "purchase"}
              id={"purchase-intake-#{dump.id}-#{answer}"}
              variant="soft"
              phx-click="intake-choose"
              phx-value-id={dump.id}
              phx-value-answer={answer}
              disabled={!@can_edit || @signed_off?}
            >{label}</.button>
          </div>
          <.form
            :let={form}
            :if={
              dump.status == "needs_confirmation" && @intake_choices[to_string(dump.id)] &&
                (dump.kind == "purchase" || @intake_choices[to_string(dump.id)] != "move")
            }
            for={
              to_form(
                %{
                  "id" => dump.id,
                  "answer" => @intake_choices[to_string(dump.id)],
                  "reason" => "",
                  "period" => (Dumps.precondition(dump) || %{})["modal_period"] || ""
                },
                as: :intake
              )
            }
            id={"purchase-intake-form-#{dump.id}"}
            phx-submit="intake-answer"
            class="space-y-related"
          >
            <.input field={form[:id]} type="hidden" id={"purchase-intake-id-#{dump.id}"} />
            <.input field={form[:answer]} type="hidden" id={"purchase-intake-answer-#{dump.id}"} />
            <.input
              :if={@intake_choices[to_string(dump.id)] == "keep"}
              field={form[:reason]}
              label="Why does this upload belong here?"
              id={"purchase-intake-reason-#{dump.id}"}
              required
            />
            <.input
              :if={@intake_choices[to_string(dump.id)] == "move"}
              field={form[:period]}
              type="month"
              label="Destination month"
              id={"purchase-intake-period-#{dump.id}"}
              required
            />
            <p :if={@intake_choices[to_string(dump.id)] == "discard"} class="text-ui">
              The original upload stays on the audit trail. Its records will not enter the working.
            </p>
            <.button
              type="submit"
              id={"purchase-intake-confirm-#{dump.id}"}
              disabled={!@can_edit || @signed_off?}
            >Confirm</.button>
          </.form>
        </section>
        <p :if={!@portal_present && @books_present} id="purchase-awaiting-2b" class="text-ui">
          Import GSTR-2B before treating missing matches as differences from the portal.
        </p>
        <div :if={@books_present} class="overflow-x-auto">
          <.navigation_tabs
            id="purchase-filters"
            items={@tabs}
            selected={@filter}
            label="Purchase reconciliation"
          />
        </div>
        <.form
          :if={@items != []}
          for={@search_form}
          id="purchase-search"
          phx-change="search"
          phx-submit="search"
        >
          <.input
            field={@search_form[:q]}
            type="search"
            label="Find supplier, GSTIN or invoice"
            phx-debounce="250"
          />
        </.form>
        <p :if={@books_present} id="purchase-result-count" class="text-ui">
          {@visible_count} {if @visible_count == 1, do: "review item", else: "review items"} · A group can contain more than one invoice; ITC checks appear separately.
        </p>
        <.data_table
          id="purchase-items"
          rows={@streams.purchase_items}
          mode="worklist"
          row_class={fn item -> if item.selected?, do: "bg-quiet", else: nil end}
        >
          <:col :let={item} label="Select">
            <.input
              :if={item.selectable?}
              id={"purchase-select-#{item.id}"}
              type="checkbox"
              name={"select-#{item.id}"}
              checked={item.selected?}
              hidden_input={false}
              checkbox_hit_area="large"
              phx-click="select-itc"
              phx-value-id={item.id}
              aria-label={"Select invoice #{item.invoice_number} from #{item.vendor}"}
              disabled={!@can_edit || @signed_off?}
            />
          </:col>
          <:col :let={item} label="Invoice" row_header>
            <.text_link
              id={"purchase-open-#{item.id}"}
              navigate={Workspace.review_path(@client.id, @period, item.id, @filter, @q)}
            >{item.invoice_number || "No invoice number"}</.text_link>
            <.context_text :if={item.document_type != "invoice"}>
              {String.replace(item.document_type, "_", " ")}
            </.context_text>
          </:col>
          <:col :let={item} label="Supplier">{item.vendor || "Unknown supplier"}</:col>
          <:col :let={item} label="Tax amount" align="right">
            {Workspace.money(item.tax_paise)}
          </:col>
          <:col :let={item} label="Result">
            {if @books_present, do: Workspace.label(item), else: "Reported in GSTR-2B"}
          </:col>
          <:col :let={item} label="ITC decision">
            <span :if={item.claim_state == "not_claiming"} id={"purchase-claim-state-#{item.id}"}>Not claiming</span>
            <p :if={item.claim_reason not in [nil, ""]} class="text-ink-muted text-ui">
              {item.claim_reason}
            </p>
            <.button
              :for={excluded <- item.claim_exclusions}
              :if={!item.selectable?}
              id={"purchase-reopen-case-#{item.id}-#{excluded.case_id}"}
              variant="ghost"
              phx-click="reopen-case-claim"
              phx-value-id={excluded.case_id}
              disabled={!@can_edit || @signed_off?}
            >Clear decision for {excluded.invoice_number}</.button>
            <span :if={item.claim_state != "not_claiming"} class="text-ink-muted">—</span>
          </:col>
        </.data_table>
        <p :if={@visible_count == 0} id="purchase-empty" class="text-ink-muted text-ui">
          {cond do
            @processing ->
              "Your records are being prepared."

            Enum.any?(@dumps, &(&1.status == "needs_confirmation")) ->
              "Answer the upload question above to continue."

            is_nil(@month) ->
              "Import the purchase register and GSTR-2B to begin."

            @items == [] ->
              "No purchase records are available for this month."

            true ->
              "No review items match this filter."
          end}
        </p>
      </div>
      <.modal
        :if={@claim_form && @selected_count > 0}
        id="purchase-claim-dialog"
        title={"Don't claim ITC for #{@selected_count} #{if @selected_count == 1, do: "invoice", else: "invoices"}?"}
        on_close="cancel-claim"
        return_focus="#purchase-exclude-itc"
      >
        <div class="space-y-block">
          <p class="text-ui">Selected tax: {Workspace.money(@selected_tax)}</p>
          <p id="purchase-selected-invoices" class="text-ink-muted text-ui">
            Invoices: {@selected_invoices}
          </p>
          <div :if={@error} id="purchase-claim-error">
            <.callout kind="error">{@error}</.callout>
          </div>
          <.form for={@claim_form} id="purchase-claim-form" phx-submit="save-claim">
            <.input
              field={@claim_form[:reason]}
              id="purchase-claim-reason"
              label="Why aren't you claiming this ITC?"
              placeholder="e.g. Personal expenses"
              required
              maxlength="1000"
              autofocus
            />
          </.form>
        </div>
        <:footer>
          <.button id="purchase-cancel-claim" variant="ghost" phx-click="cancel-claim">Cancel</.button>
          <.button
            id="purchase-save-claim"
            type="submit"
            form="purchase-claim-form"
            disabled={!@can_edit || @signed_off?}
            phx-disable-with="Saving…"
          >Don't claim ITC</.button>
        </:footer>
      </.modal>
      <:bottom_bar>
        <Layouts.bottom_bar :if={@selected_count > 0} id="purchase-bulk-bar" animate>
          <div
            id="purchase-selection"
            class="gap-related flex flex-wrap items-center justify-between"
            role="region"
            aria-label="Selected invoices"
          >
            <p id="purchase-selection-count" class="text-ui font-semibold" aria-live="polite">
              {@selected_count} selected · {Workspace.money(@selected_tax)} tax<span :if={
                @hidden_selected_count > 0
              }> · {@hidden_selected_count} outside this filter</span>
            </p>
            <div class="gap-related flex flex-wrap items-center">
              <.button id="purchase-clear-selection" variant="ghost" phx-click="clear-selection">Clear selection</.button>
              <.button
                :if={@can_reopen_claim}
                id="purchase-reopen-itc"
                variant="outline"
                phx-click="reopen-claim"
                disabled={!@can_edit || @signed_off?}
              >Clear ITC decision</.button>
              <.button
                id="purchase-exclude-itc"
                phx-click="exclude-itc"
                disabled={!@can_edit || @signed_off?}
              >Don't claim ITC</.button>
            </div>
          </div>
        </Layouts.bottom_bar>
      </:bottom_bar>
    </Layouts.app>
    """
  end
end
