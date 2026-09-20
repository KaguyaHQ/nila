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
  alias NilaWeb.Components.Gst.{PeriodHeader, PurchaseOverview}

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
           filing_picker_year: Date.from_iso8601!(period <> "-01").year,
           filter: "needs_review",
           q: "",
           error: nil,
           selected: MapSet.new(),
           treatment_form: nil,
           treatment_choice: nil,
           carried_modal?: false,
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
  def handle_event("shift-filing-year", %{"direction" => direction}, socket)
      when direction in ["previous", "next"] do
    offset = if direction == "previous", do: -1, else: 1

    {:noreply,
     assign(
       socket,
       :filing_picker_year,
       min(Date.utc_today().year, max(1, socket.assigns.filing_picker_year + offset))
     )}
  end

  def handle_event("filter", %{"filter" => %{"value" => value}}, socket) do
    {:noreply,
     push_patch(socket,
       to:
         Workspace.list_path(
           socket.assigns.client.id,
           socket.assigns.period,
           value,
           socket.assigns.q
         )
     )}
  end

  def handle_event("select-itc", %{"id" => id}, socket) do
    item =
      Enum.find(
        socket.assigns.items,
        &(&1.id == id and &1.selectable? and not Workspace.pairing_pending?(&1))
      )

    if item && socket.assigns.can_edit && !socket.assigns.signed_off? do
      selected = socket.assigns.selected

      selected =
        if MapSet.member?(selected, item.case_id),
          do: MapSet.delete(selected, item.case_id),
          else: MapSet.put(selected, item.case_id)

      {:noreply, socket |> assign(selected: selected, treatment_form: nil) |> rows()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("clear-selection", _, socket),
    do: {:noreply, socket |> assign(selected: MapSet.new(), treatment_form: nil) |> rows()}

  def handle_event("open-treatment", _, socket) do
    if socket.assigns.can_edit && !socket.assigns.signed_off? && socket.assigns.selected_count > 0 do
      line =
        case Enum.filter(
               socket.assigns.items,
               &MapSet.member?(socket.assigns.selected, &1.case_id)
             ) do
          [item] -> List.first(item.treatment_lines)
          _ -> nil
        end

      {choice, values} = initial_treatment(line)

      {:noreply,
       assign(socket,
         error: nil,
         carried_modal?: false,
         treatment_choice: choice,
         treatment_form: to_form(values, as: :treatment)
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel-treatment", _, socket) do
    socket = assign(socket, treatment_form: nil)

    if socket.assigns.carried_modal?,
      do: {:noreply, socket |> assign(selected: MapSet.new(), carried_modal?: false) |> rows()},
      else: {:noreply, socket}
  end

  def handle_event("choose-itc-treatment", %{"choice" => choice}, socket)
      when choice in ~w(claim later exclude split) do
    if choice == "split" and socket.assigns.selected_count != 1 do
      {:noreply, assign(socket, error: "Select one invoice to split its tax heads.")}
    else
      {:noreply, assign(socket, treatment_choice: choice, error: nil)}
    end
  end

  def handle_event("open-carried-treatment", %{"id" => id}, socket) do
    line = Enum.find(socket.assigns.carried_cases, &(to_string(&1.case_id) == id))

    if line && socket.assigns.can_edit && !socket.assigns.signed_off? do
      tax = line.outstanding_heads |> Map.values() |> Enum.sum()
      {choice, values} = initial_treatment(line)

      {:noreply,
       assign(socket,
         selected: MapSet.new([line.case_id]),
         selected_count: 1,
         selected_tax: tax,
         selected_invoices: line.invoice_number || "Earlier invoice",
         can_claim_selection: line.claimable?,
         claim_block_reason: line.claim_block_reason,
         selected_heads: line.outstanding_heads,
         selected_cess_issue:
           Nila.Gst.Cess.purchase_issue(line.invoice_date, line.outstanding_heads),
         selected_cess_visible?: cess_visible?(line),
         selected_stale?: line.treatment_stale?,
         treatment_choice: choice,
         carried_modal?: true,
         error: nil,
         treatment_form: to_form(values, as: :treatment)
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("record-carried-document", %{"id" => id}, socket) do
    a = socket.assigns

    case_id =
      case Integer.parse(id) do
        {n, ""} -> n
        _ -> nil
      end

    line = Enum.find(a.carried_cases, &(&1.case_id == case_id))

    if line && line.has_gstr2b? && !line.has_books? && line.document_state != "held" &&
         a.can_edit && !a.signed_off? do
      case ItcDecisions.record_document(a.current_scope, a.client.id, a.period, case_id) do
        {:ok, _} -> {:noreply, socket |> put_flash(:info, "Document status saved.") |> reload()}
        {:error, reason} -> {:noreply, assign(socket, error: carried_document_error(reason))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("apply-treatment", %{"treatment" => params}, socket) do
    a = socket.assigns
    attrs = Map.put(params, "choice", a.treatment_choice)

    result =
      with {:ok, attrs} <- treatment_attrs(attrs),
           true <- a.can_edit and not a.signed_off? and a.selected_count > 0 do
        ItcDecisions.apply(
          a.current_scope,
          a.client.id,
          a.period,
          MapSet.to_list(a.selected),
          attrs
        )
      else
        {:error, _} = error -> error
        _ -> {:error, :unavailable}
      end

    socket = assign(socket, treatment_form: to_form(params, as: :treatment))
    treatment_result(socket, result)
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

  defp treatment_result(socket, {:ok, _}) do
    {:noreply,
     socket
     |> assign(
       selected: MapSet.new(),
       treatment_form: nil,
       treatment_choice: nil,
       carried_modal?: false,
       error: nil
     )
     |> put_flash(:info, "ITC treatment saved.")
     |> reload()}
  end

  defp treatment_result(socket, {:error, reason}) do
    message =
      case reason do
        :reason_required ->
          "Choose a reason for this treatment."

        :note_required ->
          "Enter a note for Other."

        :amounts_do_not_balance ->
          "Split amounts must add up to each available tax head."

        :invalid_amounts ->
          "Enter rupee amounts with no more than two decimal places."

        :invalid_amount ->
          "Enter rupee amounts with no more than two decimal places."

        :claim_not_available ->
          "Claim is blocked for a selected invoice. Review its checks first."

        :cess_review_required ->
          "CESS needs separate review and cannot be claimed or carried forward in Nila."

        :itc_blocked ->
          "Claim is blocked for a selected invoice. Review its checks first."

        :later_treatment_exists ->
          "A later month already has a treatment for this invoice. Change that month first."

        :later_signed_treatment ->
          "A later signed working depends on this invoice. Reopen that month first."

        :already_allocated ->
          "This credit is already included in a signed working. Reopen that working first."

        :signed_off ->
          "This month is signed off or filed. Reopen it before changing ITC decisions."

        _ ->
          if(is_binary(reason),
            do: reason,
            else: "Could not save the treatment. Review the selected invoices and try again."
          )
      end

    message =
      if reason == :reason_required and other_without_note?(socket.assigns.treatment_form.params),
        do: "Enter a note for Other.",
        else: message

    socket = if socket.assigns.carried_modal?, do: socket, else: reload(socket)
    {:noreply, assign(socket, error: message)}
  end

  defp other_without_note?(params) do
    (params["later_reason"] == "other" or params["exclude_reason"] == "other") and
      String.trim(params["note"] || "") == ""
  end

  defp treatment_attrs(%{"choice" => "split"} = attrs) do
    split = Map.get(attrs, "split", %{})

    with {:ok, heads} <- parse_split_heads(split) do
      {:ok, attrs |> Map.drop(["split"]) |> Map.merge(heads)}
    end
  end

  defp treatment_attrs(%{"choice" => choice} = attrs) when choice in ~w(claim later exclude),
    do: {:ok, Map.drop(attrs, ["split"])}

  defp treatment_attrs(_), do: {:error, "Choose an ITC treatment."}

  defp parse_split_heads(split) do
    parsed =
      for treatment <- ~w(claim later exclude), into: %{} do
        amounts = Map.get(split, treatment, %{})

        values =
          for head <- ~w(cgst sgst igst cess), into: %{} do
            {head, parse_rupees(Map.get(amounts, head, "0"))}
          end

        {treatment, values}
      end

    if Enum.any?(parsed, fn {_name, heads} ->
         Enum.any?(heads, fn {_head, value} -> value == :error end)
       end),
       do: {:error, :invalid_amount},
       else: {:ok, parsed}
  end

  defp parse_rupees(value) when is_binary(value) do
    value = String.trim(value)

    if Regex.match?(~r/\A\d{1,13}(?:\.\d{1,2})?\z/, value) do
      [whole | decimals] = String.split(value, ".")

      String.to_integer(whole) * 100 +
        String.to_integer(String.pad_trailing(List.first(decimals) || "0", 2, "0"))
    else
      :error
    end
  end

  defp parse_rupees(_), do: :error

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
          Enum.any?(a.items, &(&1.kind == :books)) or
          Workspace.source_rows(a.workings, "register") != [],
      portal_present: effective != [] or Workspace.source_rows(a.workings, "gstr2b") != [],
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
    do: "Set ITC treatment for these invoices, or import purchase Excel to compare with books."

  defp next_step(%{books_present: false}),
    do: "Import the client's purchase register, then compare it with GSTR-2B."

  defp next_step(%{statement_needs_import: true}),
    do: "GSTR-2B has been fetched. Start reconciliation against the client's purchase records."

  defp next_step(%{portal_present: false}),
    do: "Purchase records are ready. Fetch GSTR-2B to compare them with supplier records."

  defp next_step(_),
    do: "Review the differences below, then download the working for your senior."

  defp period_path(a, period) do
    if a.live_action == :index,
      do: Workspace.overview_path(a.client.id, period),
      else: Workspace.list_path(a.client.id, period, a.filter, "")
  end

  defp rows(socket) do
    selectable_ids =
      socket.assigns.items
      |> Enum.filter(&(&1.selectable? and not Workspace.pairing_pending?(&1)))
      |> MapSet.new(& &1.case_id)

    socket =
      assign(socket, :selected, MapSet.intersection(socket.assigns.selected, selectable_ids))

    a = socket.assigns
    filter = if !a.books_present and a.filter == "needs_review", do: "all", else: a.filter
    visible = Workspace.filter(a.items, filter, a.q)

    selected_items =
      Enum.filter(a.items, &MapSet.member?(a.selected, &1.case_id)) |> Enum.uniq_by(& &1.case_id)

    visible = Enum.map(visible, &Map.put(&1, :selected?, MapSet.member?(a.selected, &1.case_id)))

    source_view? = a.filter in ["register", "gstr2b"]
    source_rows = if source_view?, do: source_list(a), else: []

    carried_visible =
      if a.filter in ~w(all treatment carried needs_review),
        do: Workspace.filter_carried(a.carried_cases, a.q),
        else: []

    socket
    |> assign(
      visible_count:
        if(source_view?, do: length(source_rows), else: length(visible) + length(carried_visible)),
      visible_carried_count: length(carried_visible),
      source_view?: source_view?,
      hidden_selected_count:
        MapSet.size(MapSet.difference(a.selected, MapSet.new(visible, & &1.case_id))),
      selected_count: length(selected_items),
      selected_tax: Enum.sum(Enum.map(selected_items, & &1.claim_tax)),
      selected_heads:
        case selected_items do
          [item] -> item.treatment_lines |> List.first() |> then(&(&1 && &1.outstanding_heads))
          _ -> nil
        end,
      selected_stale?: Enum.any?(selected_items, &Map.get(&1, :treatment_stale?, false)),
      selected_cess_issue:
        selected_items
        |> Enum.flat_map(& &1.treatment_lines)
        |> Enum.find_value(&Nila.Gst.Cess.purchase_issue(&1.invoice_date, &1.outstanding_heads)),
      selected_cess_visible?:
        selected_items |> Enum.flat_map(& &1.treatment_lines) |> Enum.any?(&cess_visible?/1),
      selected_invoices:
        Enum.map_join(selected_items, ", ", &(&1.invoice_number || "No invoice number")),
      can_claim_selection: Enum.all?(selected_items, &Map.get(&1, :claimable?, true)),
      claim_block_reason: selected_items |> Enum.find_value(&Map.get(&1, :claim_block_reason)),
      filter_form: to_form(%{"value" => a.filter}, as: :filter),
      overview: Workspace.overview(a.workings, a.items),
      inputs_unresolved?:
        Enum.any?(a.dumps, &(&1.status in ~w(failed needs_confirmation held after_filing))),
      search_form: to_form(%{"q" => a.q}, as: :search)
    )
    |> stream(:purchase_items, visible, reset: true)
    |> stream(:carried_cases, carried_visible, reset: true)
    |> stream(:source_items, source_rows, reset: true)
  end

  defp source_list(a) do
    query = String.downcase(a.q)

    a.workings
    |> Workspace.source_rows(a.filter)
    |> Enum.with_index()
    |> Enum.flat_map(fn {record, index} ->
      text = Enum.map_join(~w(vendor_name vendor_gstin invoice_number), " ", &(record[&1] || ""))

      if String.contains?(String.downcase(text), query) do
        item =
          Enum.find(a.items, fn item ->
            item.kind != :itc and
              if(a.filter == "register",
                do: Enum.any?(item.books_members, &(&1["id"] == record["id"])),
                else:
                  Enum.any?(
                    item.counterparts,
                    &(Nila.Gst.Purchase.Reconciliation.gstr2b_ref(&1) ==
                        Nila.Gst.Purchase.Reconciliation.gstr2b_ref(record))
                  )
              )
          end)

        claim =
          Enum.find(a.workings.case_lines, fn line ->
            source = if a.filter == "register", do: "books", else: "gstr2b"

            ref =
              if a.filter == "register",
                do: record["id"],
                else: Nila.Gst.Purchase.Reconciliation.gstr2b_ref(record)

            get_in(line.source_refs, [source, a.period]) == ref
          end)

        [
          %{
            id: "source-#{index}",
            record: record,
            item: item,
            claim: claim,
            tax: Workspace.source_tax(record)
          }
        ]
      else
        []
      end
    end)
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
        <PeriodHeader.period_header
          client={@client}
          period={@period}
          picker_year={@filing_picker_year}
          section="Purchases & ITC"
          path_for_period={fn period -> period_path(assigns, period) end}
        />
        <div :if={@live_action == :register} class="space-y-block">
          <.text_link
            id="purchase-overview-link"
            navigate={Workspace.overview_path(@client.id, @period)}
          >← Purchases &amp; ITC overview</.text_link>
          <.page_header title={
            case @filter do
              "register" -> "Purchase register"
              "gstr2b" -> "GSTR-2B"
              _ -> "Purchase review"
            end
          }>
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
        </div>

        <div :if={@error} id="purchase-error">
          <.callout kind="error">{@error}</.callout>
        </div>

        <p :if={@signed_off?} id="purchase-frozen" class="text-ui">
          This month is signed off or filed. Review is read-only.
        </p>

        <div
          :if={@live_action == :register}
          class="gap-block flex flex-wrap items-center justify-between"
        >
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

        <PurchaseOverview.overview
          :if={@live_action == :index}
          client={@client}
          period={@period}
          overview={@overview}
          books_present={@books_present}
          portal_present={@portal_present}
          can_edit={@can_edit}
          signed_off?={@signed_off?}
          can_export={@can_export}
          month={@month}
          processing={@processing}
          inputs_unresolved?={@inputs_unresolved?}
          statement_needs_import={@statement_needs_import}
        />
        <div :if={@live_action == :register} class="space-y-block">
          <p :if={!@portal_present && @books_present} id="purchase-awaiting-2b" class="text-ui">
            Import GSTR-2B before treating missing matches as differences from the portal.
          </p>

          <.form :if={@books_present} for={@filter_form} id="purchase-filters" phx-change="filter">
            <.input
              field={@filter_form[:value]}
              type="select"
              label="Show"
              options={Enum.map(Workspace.filters(), fn {value, label} -> {label, value} end)}
            />
          </.form>

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
              data-shortcut-search
              phx-debounce="250"
            />
          </.form>

          <p :if={@books_present && !@source_view?} id="purchase-result-count" class="text-ui">
            {@visible_count} {if @visible_count == 1, do: "review item", else: "review items"} · A group can contain more than one invoice; ITC checks appear separately.
          </p>

          <.data_table
            :if={@source_view?}
            id="purchase-source-items"
            rows={@streams.source_items}
            mode="scan"
          >
            <:col :let={row} label="Select">
              <.input
                :if={row.item && row.item.selectable? && !Workspace.pairing_pending?(row.item)}
                id={"purchase-source-select-#{row.id}"}
                type="checkbox"
                name={row.id}
                checked={MapSet.member?(@selected, row.item.case_id)}
                hidden_input={false}
                checkbox_hit_area="large"
                phx-click="select-itc"
                phx-value-id={row.item.id}
                aria-label={"Select invoice #{row.record["invoice_number"]}"}
                disabled={!@can_edit || @signed_off?}
              />
            </:col>

            <:col :let={row} label="Invoice" row_header>
              <.text_link
                :if={row.item}
                navigate={Workspace.review_path(@client.id, @period, row.item.id, @filter, @q)}
              >{row.record["invoice_number"] || "No invoice number"}</.text_link>
              <span :if={!row.item}>{row.record["invoice_number"] || "No invoice number"}</span>
            </:col>

            <:col :let={row} label="Supplier">
              {row.record["vendor_name"] || row.record["vendor_gstin"] || "Unknown supplier"}
            </:col>

            <:col :let={row} label="Date">{row.record["invoice_date"]}</:col>

            <:col :let={row} label="GST" align="right">{Workspace.money(row.tax)}</:col>

            <:col :let={row} label="ITC decision">
              {if row.claim && row.claim.treatment,
                do: treatment_label(row.claim.treatment),
                else: "—"}
            </:col>
          </.data_table>

          <.data_table
            :if={!@source_view?}
            id="purchase-items"
            rows={@streams.purchase_items}
            mode="worklist"
            row_class={fn item -> if item.selected?, do: "bg-quiet", else: nil end}
          >
            <:col :let={item} label="Select">
              <.input
                :if={item.selectable? && !Workspace.pairing_pending?(item)}
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
              <span id={"purchase-treatment-state-#{item.id}"}>{treatment_label(
                Map.get(item, :treatment)
              )}</span>
            </:col>
          </.data_table>

          <section
            :if={@visible_carried_count > 0 and not @source_view?}
            class="space-y-related"
            id="purchase-carried-credit"
          >
            <h2 class="text-h4">Credit from earlier months</h2>
            <.data_table id="purchase-carried-items" rows={@streams.carried_cases} mode="worklist">
              <:col :let={line} label="Invoice" row_header>
                {line.invoice_number || "No invoice number"}
              </:col>
              <:col :let={line} label="Supplier">{line.vendor || "Unknown supplier"}</:col>
              <:col :let={line} label="From month">{line.origin_period}</:col>
              <:col :let={line} label="Available GST" align="right">
                {Workspace.money(Enum.sum(Map.values(line.outstanding_heads)))}
              </:col>
              <:col :let={line} label="ITC treatment">{treatment_label(line.treatment)}</:col>
              <:col :let={line} label="Action">
                <.button
                  :if={line.has_gstr2b? && !line.has_books? && line.document_state != "held"}
                  id={"purchase-carried-document-#{line.case_id}"}
                  variant="soft"
                  phx-click="record-carried-document"
                  phx-value-id={line.case_id}
                  disabled={!@can_edit || @signed_off?}
                >Client holds invoice</.button>
                <.button
                  id={"purchase-carried-treatment-#{line.case_id}"}
                  variant="soft"
                  phx-click="open-carried-treatment"
                  phx-value-id={line.case_id}
                  disabled={!@can_edit || @signed_off?}
                >Set treatment</.button>
              </:col>
            </.data_table>
          </section>

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
      </div>

      <.modal
        :if={@treatment_form && @selected_count > 0}
        id="purchase-treatment-dialog"
        title={"Set ITC treatment for #{@selected_count} #{if @selected_count == 1, do: "invoice", else: "invoices"}"}
        on_close="cancel-treatment"
        return_focus={
          if @carried_modal?,
            do: "#purchase-carried-treatment-#{List.first(MapSet.to_list(@selected))}",
            else: "#purchase-set-treatment"
        }
      >
        <div class="space-y-block">
          <p class="text-ui">Selected tax: {Workspace.money(@selected_tax)}</p>

          <p id="purchase-selected-invoices" class="text-ink-muted text-ui">
            Invoices: {@selected_invoices}
          </p>
          <.callout :if={@selected_stale?} kind="warning">
            Source amounts changed. Review and save treatment again.
          </.callout>

          <div :if={@error} id="purchase-treatment-error">
            <.callout kind="error">{@error}</.callout>
          </div>

          <.form
            for={@treatment_form}
            id="purchase-treatment-form"
            phx-submit="apply-treatment"
            class="space-y-block"
            data-shortcut-save
          >
            <.input
              field={@treatment_form[:choice]}
              id="purchase-treatment-choice"
              type="hidden"
              value={@treatment_choice || ""}
            />
            <div class="gap-related flex flex-wrap">
              <.button
                :for={{choice, label} <- treatment_choices(@period, @selected_count)}
                id={"purchase-choice-#{choice}"}
                type="button"
                variant={if @treatment_choice == choice, do: "primary", else: "soft"}
                aria-pressed={to_string(@treatment_choice == choice)}
                phx-click="choose-itc-treatment"
                phx-value-choice={choice}
                disabled={
                  (choice == "claim" and !@can_claim_selection) or
                    (choice in ["claim", "later"] and not is_nil(@selected_cess_issue)) or
                    (choice == "split" and @selected_count != 1)
                }
              >{label}</.button>
            </div>
            <p
              :if={!@can_claim_selection}
              id="purchase-claim-block-reason"
              class="text-ink-muted text-ui"
            >
              Claim is unavailable: {@claim_block_reason ||
                "Review the selected invoice's checks first."}
            </p>
            <p :if={@selected_count > 1} class="text-ink-muted text-ui">
              Select one invoice to split its tax heads.
            </p>
            <p :if={@selected_cess_issue} id="purchase-cess-review" class="text-ink-muted text-ui">
              {@selected_cess_issue}
            </p>
            <.input
              :if={@treatment_choice in ["later", "split"]}
              field={@treatment_form[:later_reason]}
              id="purchase-later-reason"
              type="select"
              label="Why claim later?"
              options={[
                {"Choose a reason", ""}
                | Enum.map(ItcDecisions.reasons("later"), fn {code, label} -> {label, code} end)
              ]}
            />
            <.input
              :if={@treatment_choice in ["exclude", "split"]}
              field={@treatment_form[:exclude_reason]}
              id="purchase-exclude-reason"
              type="select"
              label="Why exclude?"
              options={[
                {"Choose a reason", ""}
                | Enum.map(ItcDecisions.reasons("exclude"), fn {code, label} -> {label, code} end)
              ]}
            />
            <div :if={@treatment_choice == "split"} id="purchase-split-heads" class="space-y-block">
              <p class="text-ui">
                Enter the rupee amounts for each tax head. Each row must add up to its available amount.
              </p>
              <div
                :for={head <- ~w(cgst sgst igst cess)}
                :if={head != "cess" or @selected_cess_visible?}
                class="gap-related grid grid-cols-3"
              >
                <p class="text-ui col-span-3">
                  {String.upcase(head)} available: {Workspace.money(
                    Map.get(@selected_heads || %{}, head, 0)
                  )}
                </p>
                <.input
                  :for={part <- ~w(claim later exclude)}
                  name={"treatment[split][#{part}][#{head}]"}
                  value={
                    if head == "cess" and part in ~w(claim later),
                      do: "0.00",
                      else: get_in(@treatment_form.params, ["split", part, head]) || "0.00"
                  }
                  disabled={head == "cess" and part in ~w(claim later)}
                  type="text"
                  id={"purchase-#{head}-#{part}"}
                  label={"#{String.upcase(head)} #{part} (₹)"}
                  inputmode="decimal"
                />
              </div>
            </div>
            <.input
              :if={@treatment_choice in ["later", "exclude", "split"]}
              field={@treatment_form[:note]}
              id="purchase-treatment-note"
              type="textarea"
              label="Note"
              maxlength="1000"
            />
          </.form>
        </div>

        <:footer>
          <.button id="purchase-cancel-treatment" variant="ghost" phx-click="cancel-treatment">Cancel</.button>
          <.button
            id="purchase-apply-treatment"
            type="submit"
            form="purchase-treatment-form"
            disabled={!@can_edit || @signed_off?}
            phx-disable-with="Saving…"
          >Save treatment</.button>
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
                id="purchase-set-treatment"
                phx-click="open-treatment"
                disabled={!@can_edit || @signed_off?}
              >Set ITC treatment</.button>
            </div>
          </div>
        </Layouts.bottom_bar>
      </:bottom_bar>
    </Layouts.app>
    """
  end

  defp treatment_choices(period, _count) do
    month = (period <> "-01") |> Date.from_iso8601!() |> Calendar.strftime("%B %Y")

    [
      {"claim", "Claim in #{month}"},
      {"later", "Claim later"},
      {"exclude", "Exclude from ITC"},
      {"split", "Split treatment"}
    ]
  end

  defp initial_treatment(nil),
    do: {nil, %{"later_reason" => "", "exclude_reason" => "", "note" => ""}}

  defp initial_treatment(line) do
    choice = if line.treatment in ~w(claim later exclude split), do: line.treatment, else: nil

    split =
      for part <- ~w(claim later exclude), into: %{} do
        values =
          for head <- ~w(cgst sgst igst cess), into: %{} do
            paise = get_in(line.treatment_heads || %{}, [part, head]) || 0
            {head, decimal_rupees(paise)}
          end

        {part, values}
      end

    {choice,
     %{
       "later_reason" => line.later_reason || "",
       "exclude_reason" => line.exclude_reason || "",
       "note" => line.treatment_note || "",
       "split" => split
     }}
  end

  defp decimal_rupees(paise),
    do: "#{div(paise, 100)}.#{String.pad_leading(to_string(rem(paise, 100)), 2, "0")}"

  defp carried_document_error(:signed_off),
    do: "This month is signed off. Reopen it before changing document status."

  defp carried_document_error(reason) when is_binary(reason), do: reason

  defp carried_document_error(_),
    do: "Could not save document status. Review the invoice and try again."

  defp cess_visible?(line),
    do: Map.get(line.tax_heads, "cess", 0) != 0 or Map.get(line.outstanding_heads, "cess", 0) != 0

  defp treatment_label("claim"), do: "Claim this month"
  defp treatment_label("later"), do: "Claim later"
  defp treatment_label("exclude"), do: "Excluded from ITC"
  defp treatment_label("split"), do: "Split treatment"
  defp treatment_label(_), do: "—"
end
