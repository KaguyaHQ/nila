defmodule NilaWeb.Banking.StatementLive do
  use NilaWeb, :live_view

  alias Nila.Accounts.Policy
  alias Nila.Banking
  alias Nila.Banking.Transaction
  alias Nila.Banking.TransactionGrouping
  alias Nila.TallyJobs

  @transaction_group_preview_limit 4

  @impl true
  def mount(%{"id" => id} = params, _session, socket) do
    org = socket.assigns.current_scope.current_org

    case Banking.get_statement(org.id, id) do
      {:ok, statement} ->
        if connected?(socket) do
          Banking.subscribe(org.id)
          TallyJobs.subscribe_org(org.id)
        end

        {:ok,
         socket
         |> assign(:page_title, "Bank statement")
         |> assign(:transaction_filters, transaction_filters_from_params(params, statement))
         |> assign(:expanded_transaction_groups, MapSet.new())
         |> assign(:fully_expanded_transaction_groups, MapSet.new())
         |> assign(:transaction_group_exclusions, %{})
         |> assign(:review_ledger_selections, %{})
         |> assign_statement(statement)}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Bank statement not found")
         |> push_navigate(to: ~p"/banking")}
    end
  end

  @impl true
  def handle_params(params, _uri, %{assigns: %{statement: statement}} = socket) do
    filters = transaction_filters_from_params(params, statement)

    socket =
      assign_filtered_transactions(
        socket,
        statement.bank_transactions,
        filters,
        socket.assigns.selected_transaction_ids
      )

    if Map.has_key?(params, "status") do
      {:noreply, socket}
    else
      {:noreply, push_patch(socket, to: transaction_filter_path(socket, filters), replace: true)}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("configure-tally", %{"tally_setup" => params}, socket) do
    with true <- Policy.can?(socket.assigns.current_scope, :edit_records),
         ledger_identity when is_binary(ledger_identity) and ledger_identity != "" <-
           params["bank_ledger_identity"],
         {:ok, _statement} <-
           Banking.configure_tally(
             org_id(socket),
             socket.assigns.statement.id,
             ledger_identity
           ) do
      {:noreply, socket |> put_flash(:info, "Tally destination saved.") |> reload_statement()}
    else
      false ->
        {:noreply, put_flash(socket, :error, "You cannot change banking records.")}

      {:error, :posting_already_started} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Tally destination cannot be changed after sending to Tally has started."
         )}

      _ ->
        {:noreply,
         put_flash(socket, :error, "Connect the client to Tally and choose a bank ledger.")}
    end
  end

  def handle_event("filter-transactions", %{"transaction_filters" => params}, socket) do
    filters =
      params
      |> Map.put_new("status", socket.assigns.transaction_filters["status"])
      |> Map.put_new("review", socket.assigns.transaction_filters["review"])
      |> normalize_transaction_filters()

    {:noreply, push_patch(socket, to: transaction_filter_path(socket, filters))}
  end

  def handle_event("toggle-transaction-group", %{"key" => key}, socket) do
    case transaction_group(socket, key) do
      nil ->
        {:noreply, socket}

      group ->
        if MapSet.member?(socket.assigns.expanded_transaction_groups, key) do
          {:noreply, collapse_transaction_group(socket, group)}
        else
          {:noreply, expand_transaction_group(socket, group)}
        end
    end
  end

  def handle_event("show-all-transaction-group", %{"key" => key}, socket) do
    case transaction_group(socket, key) do
      nil -> {:noreply, socket}
      group -> {:noreply, show_all_transaction_group(socket, group)}
    end
  end

  def handle_event("toggle-transaction-group-member", %{"key" => key, "id" => value}, socket) do
    with %{transaction_ids: transaction_ids} <- transaction_group(socket, key),
         id when is_integer(id) <- positive_integer(value),
         true <- MapSet.member?(transaction_ids, id) do
      excluded = Map.get(socket.assigns.transaction_group_exclusions, key, MapSet.new())

      excluded = toggle_id(excluded, id)
      count_delta = if MapSet.member?(excluded, id), do: 1, else: -1
      exclusions = Map.put(socket.assigns.transaction_group_exclusions, key, excluded)
      group = apply_group_exclusions(transaction_group(socket, key), excluded)

      {:noreply,
       socket
       |> assign(:transaction_group_exclusions, exclusions)
       |> put_transaction_group(group)
       |> adjust_review_individual_count(count_delta)
       |> refresh_transaction_group(group)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("open-transaction-group-ledger-picker", %{"key" => key}, socket) do
    context = {:review_group, key}

    if review_ledger_context_available?(socket, context) do
      {:noreply, assign_ledger_picker(socket, context, "")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("open-review-transaction-ledger-picker", %{"id" => value}, socket) do
    with id when is_integer(id) <- positive_integer(value),
         context = {:review_transaction, id},
         true <- review_ledger_context_available?(socket, context) do
      {:noreply, assign_ledger_picker(socket, context, "")}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("apply-transaction-group", %{"key" => key}, socket) do
    context = {:review_group, key}

    with true <- socket.assigns.can_edit,
         %{included_transactions: [_ | _] = transactions} <- transaction_group(socket, key),
         ledger when not is_nil(ledger) <- review_ledger(socket, context),
         {:ok, mapped} <-
           Banking.map_transactions(
             org_id(socket),
             socket.assigns.statement.id,
             Enum.map(transactions, & &1.id),
             ledger.identity
           ) do
      {:noreply,
       socket
       |> drop_review_ledger(context)
       |> put_flash(
         :info,
         "Applied #{ledger.name} to #{transaction_count_text(length(mapped))}."
       )
       |> reload_statement()}
    else
      false -> {:noreply, put_flash(socket, :error, "You cannot change banking records.")}
      _ -> {:noreply, put_flash(socket, :error, "That group could not be mapped.")}
    end
  end

  def handle_event("apply-review-transaction", %{"id" => value}, socket) do
    with true <- socket.assigns.can_edit,
         id when is_integer(id) <- positive_integer(value),
         context = {:review_transaction, id},
         true <- review_ledger_context_available?(socket, context),
         ledger when not is_nil(ledger) <- review_ledger(socket, context),
         {:ok, [_transaction]} <-
           Banking.map_transactions(
             org_id(socket),
             socket.assigns.statement.id,
             [id],
             ledger.identity
           ) do
      {:noreply,
       socket
       |> drop_review_ledger(context)
       |> put_flash(:info, "Ledger applied.")
       |> reload_statement()}
    else
      false -> {:noreply, put_flash(socket, :error, "You cannot change banking records.")}
      _ -> {:noreply, put_flash(socket, :error, "That transaction could not be mapped.")}
    end
  end

  def handle_event("open-bulk-ledger-picker", _params, socket) do
    if bulk_ledger_available?(socket.assigns) do
      {:noreply, assign_ledger_picker(socket, :bulk, "")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("open-ledger-picker", %{"id" => value}, socket) do
    with true <- socket.assigns.can_edit,
         id when is_integer(id) <- positive_integer(value),
         %Transaction{} = transaction <- transaction_by_id(socket, id),
         true <- selectable_transaction?(transaction),
         true <- is_integer(socket.assigns.statement.tally_company_id),
         true <- is_binary(socket.assigns.statement.bank_ledger_identity),
         true <- socket.assigns.tally_ledgers != [] do
      {:noreply, assign_ledger_picker(socket, transaction, "")}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("filter-ledger-picker", %{"ledger_filter" => params}, socket) do
    case active_ledger_picker_context(socket) do
      nil ->
        {:noreply, socket}

      context ->
        {:noreply, assign_ledger_picker(socket, context, Map.get(params, "query", ""))}
    end
  end

  def handle_event("select-ledger-by-query", _params, socket) do
    case socket.assigns.ledger_picker_options do
      [ledger] -> select_ledger(socket, ledger.identity)
      _ -> {:noreply, socket}
    end
  end

  def handle_event("select-ledger", %{"identity" => identity}, socket),
    do: select_ledger(socket, identity)

  def handle_event("toggle-all-transactions", _params, socket) do
    selected_ids =
      if socket.assigns.all_transactions_selected,
        do: MapSet.new(),
        else: socket.assigns.selectable_transaction_ids

    {:noreply, assign_transaction_selection(socket, selected_ids)}
  end

  def handle_event("toggle-transaction", %{"id" => value}, socket) do
    with id when is_integer(id) <- positive_integer(value),
         true <- MapSet.member?(socket.assigns.selectable_transaction_ids, id) do
      selected_ids = toggle_id(socket.assigns.selected_transaction_ids, id)

      {:noreply, assign_transaction_selection(socket, selected_ids)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("bank-transactions", params, socket) do
    with true <- Policy.can?(socket.assigns.current_scope, :edit_records),
         {:ok, transaction_ids} <- parse_ids(params["transaction_ids"]) do
      handle_transaction_action(params["action"], transaction_ids, params, socket)
    else
      false -> {:noreply, put_flash(socket, :error, "You cannot change banking records.")}
      _ -> {:noreply, put_flash(socket, :error, "Select at least one transaction.")}
    end
  end

  @impl true
  def handle_info({:bank_statement_progress, statement_id, _state}, socket)
      when statement_id == socket.assigns.statement.id do
    org_id = socket.assigns.current_scope.current_org.id

    case Banking.get_statement(org_id, statement_id) do
      {:ok, statement} -> {:noreply, assign_statement(socket, statement)}
      {:error, :not_found} -> {:noreply, push_navigate(socket, to: ~p"/banking")}
    end
  end

  def handle_info(:tally_jobs_changed, socket), do: {:noreply, reload_statement(socket)}

  def handle_info({:change_bank_voucher_type, ids, type}, socket) do
    if Policy.can?(socket.assigns.current_scope, :edit_records) do
      case Banking.change_voucher_type(org_id(socket), socket.assigns.statement.id, ids, type) do
        {:ok, transactions} ->
          {:noreply,
           socket
           |> put_flash(:info, "Voucher type updated for #{length(transactions)} transactions.")
           |> reload_statement()}

        {:error, _reason} ->
          {:noreply,
           put_flash(socket, :error, "Voucher type could not be changed. Check the selection.")}
      end
    else
      {:noreply, put_flash(socket, :error, "You cannot change banking records.")}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp assign_statement(socket, statement) do
    transactions = if statement.status == "ready", do: statement.bank_transactions, else: []
    tally_company = Banking.tally_destination(statement)
    can_edit = Policy.can?(socket.assigns.current_scope, :edit_records)
    filters = socket.assigns[:transaction_filters] || default_transaction_filters(statement)

    selected_company_id = tally_company && tally_company.id

    ledgers =
      if selected_company_id do
        statement.org_id
        |> Banking.list_tally_ledgers(selected_company_id)
        |> Enum.reject(&(&1.identity == statement.bank_ledger_identity))
      else
        []
      end

    bank_ledgers =
      if selected_company_id,
        do: Banking.list_tally_bank_ledgers(statement.org_id, selected_company_id),
        else: []

    socket
    |> assign(:statement, statement)
    |> assign(:running_balances_match, Banking.running_balances_match?(statement))
    |> assign(:can_edit, can_edit)
    |> assign(:tally_destination_locked, posting_started?(statement))
    |> assign(:transaction_count, length(transactions))
    |> assign(:tally_company, tally_company)
    |> assign(:selected_company_id, selected_company_id)
    |> assign(:tally_ledgers, ledgers)
    |> assign(:tally_bank_ledgers, bank_ledgers)
    |> assign(:tally_setup_form, tally_setup_form(statement))
    |> reset_ledger_picker()
    |> assign(:bulk_ledger, nil)
    |> assign(:transaction_form, transaction_form())
    |> assign_filtered_transactions(transactions, filters, MapSet.new())
  end

  defp reload_statement(socket) do
    case Banking.get_statement(org_id(socket), socket.assigns.statement.id) do
      {:ok, statement} -> assign_statement(socket, statement)
      {:error, :not_found} -> push_navigate(socket, to: ~p"/banking")
    end
  end

  defp posting_started?(statement) do
    Enum.any?(statement.bank_transactions, &(&1.status in ["queued", "posted", "verifying"]))
  end

  defp tally_destination_lock_detail(statement) do
    case Enum.count(statement.bank_transactions, &(&1.status == "posted")) do
      0 -> "Sending to Tally has started"
      1 -> "1 transaction sent to Tally"
      count -> "#{count} transactions sent to Tally"
    end
  end

  defp select_ledger(%{assigns: %{ledger_picker_transaction_id: context}} = socket, identity)
       when is_tuple(context) and is_binary(identity) do
    with true <- review_ledger_context_available?(socket, context),
         ledger when not is_nil(ledger) <-
           Enum.find(socket.assigns.tally_ledgers, &(&1.identity == identity)) do
      selections = Map.put(socket.assigns.review_ledger_selections, context, ledger)

      {:noreply,
       socket
       |> assign(:review_ledger_selections, selections)
       |> reset_ledger_picker()
       |> refresh_review_context(context)}
    else
      _ -> {:noreply, put_flash(socket, :error, "Choose a synced ledger.")}
    end
  end

  defp select_ledger(%{assigns: %{ledger_picker_transaction_id: :bulk}} = socket, identity)
       when is_binary(identity) do
    with true <- bulk_ledger_available?(socket.assigns),
         ledger when not is_nil(ledger) <-
           Enum.find(socket.assigns.tally_ledgers, &(&1.identity == identity)) do
      {:noreply, socket |> assign(:bulk_ledger, ledger) |> reset_ledger_picker()}
    else
      _ ->
        {:noreply, put_flash(socket, :error, "Choose a synced ledger for selected transactions.")}
    end
  end

  defp select_ledger(socket, identity) when is_binary(identity) do
    with true <- socket.assigns.can_edit,
         id when is_integer(id) <- socket.assigns.ledger_picker_transaction_id,
         {:ok, [_transaction]} <-
           Banking.map_transactions(
             org_id(socket),
             socket.assigns.statement.id,
             [id],
             identity,
             nil
           ) do
      {:noreply,
       socket
       |> put_flash(:info, "Ledger assigned.")
       |> reload_statement()}
    else
      false -> {:noreply, put_flash(socket, :error, "You cannot change banking records.")}
      _ -> {:noreply, put_flash(socket, :error, "That ledger could not be assigned.")}
    end
  end

  defp select_ledger(socket, _identity),
    do: {:noreply, put_flash(socket, :error, "Choose a synced ledger.")}

  defp handle_transaction_action("map", ids, params, socket) do
    case Banking.map_transactions(
           org_id(socket),
           socket.assigns.statement.id,
           ids,
           params["counter_ledger_identity"]
         ) do
      {:ok, transactions} ->
        {:noreply,
         socket
         |> put_flash(:info, "Mapped #{length(transactions)} transactions.")
         |> reload_statement()}

      _ ->
        {:noreply,
         put_flash(socket, :error, "Choose a valid ledger and compatible transaction type.")}
    end
  end

  defp handle_transaction_action("send", ids, _params, socket) do
    case Banking.enqueue_transactions(org_id(socket), socket.assigns.statement.id, ids) do
      {:ok, transactions} ->
        {:noreply,
         socket
         |> put_flash(:info, "Queued #{length(transactions)} transactions for Tally.")
         |> reload_statement()}

      {:error, {:missing_ledgers, names}} ->
        {:noreply, put_flash(socket, :error, "Missing in Tally: #{Enum.join(names, ", ")}.")}

      {:error, :no_ready_transactions} ->
        {:noreply, put_flash(socket, :error, "Map the selected transactions before sending.")}

      {:error, :balance_check_failed} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Balance check failed. Review the statement before sending to Tally."
         )}

      _ ->
        {:noreply, put_flash(socket, :error, "Tally is unavailable or the selection changed.")}
    end
  end

  defp handle_transaction_action(action, ids, _params, socket)
       when action in ["ignore", "restore"] do
    ids = applicable_ignore_action_ids(socket.assigns.statement, ids, action)

    case Banking.set_ignored(
           org_id(socket),
           socket.assigns.statement.id,
           ids,
           action == "ignore"
         ) do
      {:ok, transactions} ->
        verb = if action == "ignore", do: "Ignored", else: "Restored"

        {:noreply,
         socket
         |> put_flash(:info, "#{verb} #{length(transactions)} transactions.")
         |> reload_statement()}

      _ ->
        {:noreply, put_flash(socket, :error, "That selection can no longer be changed.")}
    end
  end

  defp handle_transaction_action(_action, _ids, _params, socket),
    do: {:noreply, put_flash(socket, :error, "Choose an action.")}

  defp reset_ledger_picker(socket) do
    socket
    |> assign(:ledger_picker_transaction_id, nil)
    |> assign(:ledger_picker_selected_identity, nil)
    |> assign(:ledger_picker_options, [])
    |> assign(:ledger_filter_form, to_form(%{"query" => ""}, as: :ledger_filter))
  end

  defp assign_ledger_picker(socket, :bulk, query) do
    identity = socket.assigns.bulk_ledger && socket.assigns.bulk_ledger.identity

    socket
    |> assign(:ledger_picker_transaction_id, :bulk)
    |> assign_ledger_options(query, identity)
  end

  defp assign_ledger_picker(socket, context, query) when is_tuple(context) do
    identity = review_ledger(socket, context) && review_ledger(socket, context).identity

    socket
    |> assign(:ledger_picker_transaction_id, context)
    |> assign_ledger_options(query, identity)
  end

  defp assign_ledger_picker(socket, transaction, query) do
    socket
    |> assign(:ledger_picker_transaction_id, transaction.id)
    |> assign_ledger_options(query, transaction.counter_ledger_identity)
  end

  defp assign_ledger_options(socket, query, selected_identity) do
    query = String.trim(query)

    socket
    |> assign(:ledger_picker_selected_identity, selected_identity)
    |> assign(
      :ledger_picker_options,
      filter_ledgers(socket.assigns.tally_ledgers, query, selected_identity)
    )
    |> assign(:ledger_filter_form, to_form(%{"query" => query}, as: :ledger_filter))
  end

  defp filter_ledgers(ledgers, query, selected_identity) do
    normalized = String.downcase(query)

    ledgers =
      if normalized == "" do
        Enum.sort_by(ledgers, &(&1.identity != selected_identity))
      else
        Enum.filter(ledgers, fn ledger ->
          [ledger.name, get_in(ledger.data || %{}, ["parent"])]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(" ")
          |> String.downcase()
          |> String.contains?(normalized)
        end)
      end

    Enum.take(ledgers, 50)
  end

  defp transaction_by_id(socket, id),
    do: Enum.find(socket.assigns.statement.bank_transactions, &(&1.id == id))

  defp active_ledger_picker_context(socket) do
    case socket.assigns.ledger_picker_transaction_id do
      :bulk ->
        if bulk_ledger_available?(socket.assigns), do: :bulk

      context when is_tuple(context) ->
        if review_ledger_context_available?(socket, context), do: context

      id when is_integer(id) ->
        transaction_by_id(socket, id)

      nil ->
        nil
    end
  end

  defp review_ledger_context_available?(socket, {:review_group, key}) do
    socket.assigns.can_edit and not is_nil(transaction_group(socket, key)) and
      ledger_picker_available?(socket.assigns)
  end

  defp review_ledger_context_available?(socket, {:review_transaction, id}) do
    socket.assigns.can_edit and MapSet.member?(socket.assigns.selectable_transaction_ids, id) and
      ledger_picker_available?(socket.assigns)
  end

  defp review_ledger_context_available?(_socket, _context), do: false

  defp ledger_picker_available?(assigns) do
    is_integer(assigns.statement.tally_company_id) and
      is_binary(assigns.statement.bank_ledger_identity) and assigns.tally_ledgers != []
  end

  defp review_ledger(socket, context),
    do: Map.get(socket.assigns.review_ledger_selections, context)

  defp drop_review_ledger(socket, context) do
    assign(
      socket,
      :review_ledger_selections,
      Map.delete(socket.assigns.review_ledger_selections, context)
    )
  end

  defp transaction_group(socket, key), do: Map.get(socket.assigns.transaction_groups, key)

  defp bulk_ledger_available?(assigns) do
    assigns.can_edit and assigns.selected_active_count > 0 and
      assigns.selected_ignored_count == 0 and
      is_integer(assigns.statement.tally_company_id) and
      is_binary(assigns.statement.bank_ledger_identity) and
      assigns.tally_ledgers != []
  end

  defp ledger_option_dom_id(ledger),
    do: "banking-ledger-option-#{:erlang.phash2(ledger.identity)}"

  defp ledger_parent(ledger), do: get_in(ledger.data || %{}, ["parent"])

  defp ledger_picker_title(:bulk), do: "Ledger for selected transactions"
  defp ledger_picker_title({:review_group, _key}), do: "Ledger for similar transactions"
  defp ledger_picker_title({:review_transaction, _id}), do: "Choose ledger"
  defp ledger_picker_title(_context), do: "Choose ledger"

  defp tally_setup_form(statement) do
    to_form(
      %{
        "bank_ledger_identity" => statement.bank_ledger_identity
      },
      as: :tally_setup
    )
  end

  defp transaction_form do
    to_form(%{"counter_ledger_identity" => ""},
      as: :bank_actions
    )
  end

  defp parse_ids(ids) when is_list(ids) and ids != [] do
    ids
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, parsed} ->
      case positive_integer(value) do
        id when is_integer(id) -> {:cont, {:ok, [id | parsed]}}
        _ -> {:halt, {:error, :invalid_ids}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.uniq(parsed)}
      error -> error
    end
  end

  defp parse_ids(_ids), do: {:error, :invalid_ids}

  defp assign_filtered_transactions(socket, transactions, filters, selected_ids) do
    visible_transactions = filter_transactions(transactions, filters)

    {transaction_rows, transaction_groups, individual_transactions} =
      transaction_rows(socket, visible_transactions, filters)

    review_inventory = review_inventory(socket, transactions)

    selectable_transactions =
      if filters["status"] == "unassigned" and filters["review"] == "groups" do
        []
      else
        individual_transactions
      end

    selectable_transaction_ids =
      selectable_transactions
      |> Enum.filter(&(socket.assigns.can_edit and selectable_transaction?(&1)))
      |> MapSet.new(& &1.id)

    socket
    |> assign(:transaction_filters, filters)
    |> assign(:transaction_filter_form, to_form(filters, as: :transaction_filters))
    |> assign(:transaction_view_tabs, transaction_view_tabs(socket, transactions, filters))
    |> assign(
      :transaction_review_tabs,
      transaction_review_tabs(
        socket,
        filters,
        length(review_inventory.groups),
        length(review_inventory.individuals)
      )
    )
    |> assign(:visible_transaction_count, length(visible_transactions))
    |> assign(:transaction_groups, Map.new(transaction_groups, &{&1.key, &1}))
    |> assign(:transaction_group_keys, Enum.map(transaction_groups, & &1.key))
    |> assign(:transaction_group_rows, Enum.map(transaction_groups, &%{kind: :group, group: &1}))
    |> assign(:transaction_group_count, length(transaction_groups))
    |> assign(
      :grouped_transaction_count,
      Enum.sum(Enum.map(transaction_groups, & &1.included_count))
    )
    |> assign(:review_group_count, length(review_inventory.groups))
    |> assign(:review_individual_count, length(review_inventory.individuals))
    |> assign(:visible_individual_count, length(individual_transactions))
    |> assign(:selectable_transaction_ids, selectable_transaction_ids)
    |> assign_transaction_selection(selected_ids)
    |> stream(:transaction_rows, transaction_rows,
      reset: true,
      dom_id: &transaction_row_dom_id/1
    )
  end

  defp default_transaction_filters(statement) do
    status =
      if Enum.any?(statement.bank_transactions, &(&1.status == "unassigned")),
        do: "unassigned",
        else: "all"

    review =
      if status == "unassigned" and
           TransactionGrouping.group(
             Enum.filter(statement.bank_transactions, &(&1.status == "unassigned"))
           ).groups != [] do
        "groups"
      else
        "individual"
      end

    %{"query" => "", "status" => status, "type" => "all", "review" => review}
  end

  defp transaction_filters_from_params(params, statement) do
    defaults = default_transaction_filters(statement)

    filters = Map.take(params, ["query", "status", "type", "review"])

    filters =
      if Map.has_key?(filters, "status"),
        do: Map.update!(filters, "status", &status_filter_value/1),
        else: filters

    defaults
    |> Map.merge(filters)
    |> normalize_transaction_filters()
  end

  defp normalize_transaction_filters(params) do
    %{
      "query" => params |> Map.get("query", "") |> String.trim(),
      "status" =>
        valid_filter(Map.get(params, "status"), Enum.map(status_filter_options(), &elem(&1, 1))),
      "type" => valid_filter(Map.get(params, "type"), Transaction.types()),
      "review" => valid_review_filter(Map.get(params, "review"))
    }
  end

  defp valid_filter(value, allowed), do: if(value in allowed, do: value, else: "all")

  defp valid_review_filter(value),
    do: if(value in ~w(groups individual), do: value, else: "groups")

  defp transaction_filter_path(socket, filters) do
    params =
      %{"status" => status_filter_param(filters["status"])}
      |> maybe_put_filter("query", filters["query"], "")
      |> maybe_put_filter("type", filters["type"], "all")
      |> maybe_put_review_filter(filters)

    ~p"/banking/#{socket.assigns.statement.id}?#{params}"
  end

  defp maybe_put_filter(params, _key, value, value), do: params
  defp maybe_put_filter(params, key, value, _default), do: Map.put(params, key, value)

  defp maybe_put_review_filter(params, %{"status" => "unassigned", "review" => review}),
    do: Map.put(params, "review", review)

  defp maybe_put_review_filter(params, _filters), do: params

  defp status_filter_param("unassigned"), do: "needs_ledger"
  defp status_filter_param(status), do: status

  defp status_filter_value("needs_ledger"), do: "unassigned"
  defp status_filter_value(status), do: status

  defp filter_transactions(transactions, filters) do
    query = String.downcase(filters["query"])

    Enum.filter(transactions, fn transaction ->
      matches_transaction_query?(transaction, query) and
        matches_status_filter?(transaction.status, filters["status"]) and
        matches_filter?(transaction.transaction_type, filters["type"])
    end)
  end

  defp transaction_rows(socket, visible_transactions, %{"status" => "unassigned"} = filters) do
    %{groups: groups, individuals: individuals} = TransactionGrouping.group(visible_transactions)

    groups =
      Enum.map(groups, fn group ->
        excluded =
          Map.get(socket.assigns.transaction_group_exclusions, group.key, MapSet.new())

        apply_group_exclusions(group, excluded)
      end)

    excluded_transactions =
      groups
      |> Enum.flat_map(fn group ->
        Enum.filter(group.transactions, &MapSet.member?(group.excluded_transaction_ids, &1.id))
      end)

    individuals =
      (individuals ++ excluded_transactions)
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(& &1.ordinal)

    rows =
      case filters["review"] do
        "groups" ->
          []

        "individual" ->
          Enum.map(individuals, &%{kind: :transaction, transaction: &1})
      end

    {rows, groups, individuals}
  end

  defp transaction_rows(_socket, visible_transactions, _filters) do
    {Enum.map(visible_transactions, &%{kind: :transaction, transaction: &1}), [],
     visible_transactions}
  end

  defp review_inventory(socket, transactions) do
    %{groups: groups, individuals: individuals} =
      transactions
      |> Enum.filter(&(&1.status == "unassigned"))
      |> TransactionGrouping.group()

    groups =
      Enum.map(groups, fn group ->
        excluded = Map.get(socket.assigns.transaction_group_exclusions, group.key, MapSet.new())
        apply_group_exclusions(group, excluded)
      end)

    excluded_transactions =
      Enum.flat_map(groups, fn group ->
        Enum.filter(group.transactions, &MapSet.member?(group.excluded_transaction_ids, &1.id))
      end)

    %{
      groups: groups,
      individuals:
        (individuals ++ excluded_transactions)
        |> Enum.uniq_by(& &1.id)
        |> Enum.sort_by(& &1.ordinal)
    }
  end

  defp apply_group_exclusions(group, excluded) do
    included_transactions =
      Enum.reject(group.transactions, &MapSet.member?(excluded, &1.id))

    Map.merge(group, %{
      excluded_transaction_ids: excluded,
      included_transactions: included_transactions,
      included_count: length(included_transactions),
      included_total_paise: Enum.sum(Enum.map(included_transactions, &transaction_amount/1))
    })
  end

  defp expand_transaction_group(socket, group) do
    socket = collapse_other_transaction_groups(socket, group.key)
    expanded = MapSet.put(socket.assigns.expanded_transaction_groups, group.key)

    socket
    |> assign(:expanded_transaction_groups, expanded)
    |> refresh_transaction_group(group)
  end

  defp collapse_other_transaction_groups(socket, key) do
    socket.assigns.expanded_transaction_groups
    |> MapSet.delete(key)
    |> Enum.reduce(socket, fn expanded_key, socket ->
      case transaction_group(socket, expanded_key) do
        nil -> socket
        group -> collapse_transaction_group(socket, group)
      end
    end)
  end

  defp collapse_transaction_group(socket, group) do
    expanded = MapSet.delete(socket.assigns.expanded_transaction_groups, group.key)

    fully_expanded =
      MapSet.delete(socket.assigns.fully_expanded_transaction_groups, group.key)

    socket
    |> assign(:expanded_transaction_groups, expanded)
    |> assign(:fully_expanded_transaction_groups, fully_expanded)
    |> refresh_transaction_group(group)
  end

  defp show_all_transaction_group(socket, group) do
    expanded? = MapSet.member?(socket.assigns.expanded_transaction_groups, group.key)

    fully_expanded? =
      MapSet.member?(socket.assigns.fully_expanded_transaction_groups, group.key)

    if expanded? and not fully_expanded? and group.count > @transaction_group_preview_limit do
      fully_expanded =
        MapSet.put(socket.assigns.fully_expanded_transaction_groups, group.key)

      socket
      |> assign(:fully_expanded_transaction_groups, fully_expanded)
      |> refresh_transaction_group(group)
    else
      socket
    end
  end

  defp put_transaction_group(socket, group) do
    groups = Map.put(socket.assigns.transaction_groups, group.key, group)

    socket
    |> assign(:transaction_groups, groups)
    |> assign(
      :transaction_group_rows,
      transaction_group_rows(groups, socket.assigns.transaction_group_keys)
    )
    |> assign(
      :grouped_transaction_count,
      groups |> Map.values() |> Enum.map(& &1.included_count) |> Enum.sum()
    )
  end

  defp adjust_review_individual_count(socket, delta) do
    individual_count = socket.assigns.review_individual_count + delta

    socket
    |> assign(:review_individual_count, individual_count)
    |> assign(
      :transaction_review_tabs,
      transaction_review_tabs(
        socket,
        socket.assigns.transaction_filters,
        socket.assigns.review_group_count,
        individual_count
      )
    )
  end

  defp refresh_transaction_group(socket, group) do
    groups = Map.put(socket.assigns.transaction_groups, group.key, group)

    socket
    |> assign(:transaction_groups, groups)
    |> assign(
      :transaction_group_rows,
      transaction_group_rows(groups, socket.assigns.transaction_group_keys)
    )
  end

  defp refresh_review_context(socket, {:review_group, key}) do
    case transaction_group(socket, key) do
      nil -> socket
      group -> refresh_transaction_group(socket, group)
    end
  end

  defp refresh_review_context(socket, {:review_transaction, id}) do
    case transaction_by_id(socket, id) do
      nil ->
        socket

      transaction ->
        stream_insert(socket, :transaction_rows, %{kind: :transaction, transaction: transaction},
          update_only: true
        )
    end
  end

  defp transaction_group_member_row(group, transaction) do
    %{
      kind: :group_member,
      group_key: group.key,
      included: not MapSet.member?(group.excluded_transaction_ids, transaction.id),
      transaction: transaction
    }
  end

  defp transaction_group_detail_rows(fully_expanded_groups, group) do
    transactions =
      if MapSet.member?(fully_expanded_groups, group.key) do
        group.transactions
      else
        Enum.take(group.transactions, @transaction_group_preview_limit)
      end

    Enum.map(transactions, &transaction_group_member_row(group, &1))
  end

  defp transaction_group_preview_limit, do: @transaction_group_preview_limit

  defp transaction_group_rows(groups, keys) do
    Enum.map(keys, fn key -> %{kind: :group, group: Map.fetch!(groups, key)} end)
  end

  defp transaction_group_detail(group) do
    pattern = if group.pattern, do: " · #{group.pattern}", else: ""

    "#{group.match_basis}#{pattern}"
  end

  defp transaction_group_coverage(group) do
    type = humanize_type(group.transaction_type) |> String.downcase()
    type = if group.included_count == 1, do: type, else: type <> "s"

    "#{group.included_count} #{type} · #{money(group.included_total_paise)} total"
  end

  defp transaction_row_dom_id(%{kind: :group, group: group}),
    do: "banking-transaction-group-#{group.key}"

  defp transaction_row_dom_id(%{kind: :group_member, transaction: transaction}),
    do: "banking-transaction-group-member-#{transaction.id}"

  defp transaction_row_dom_id(%{kind: :group_more, group_key: key}),
    do: "banking-transaction-group-more-#{key}"

  defp transaction_row_dom_id(%{kind: :transaction, transaction: transaction}),
    do: "bank-transaction-#{transaction.id}"

  defp row_transaction(%{kind: kind, transaction: transaction})
       when kind in [:transaction, :group_member],
       do: transaction

  defp row_transaction(_row), do: nil

  defp matches_transaction_query?(_transaction, ""), do: true

  defp matches_transaction_query?(transaction, query) do
    [transaction.narration, transaction.reference, transaction.counter_ledger_name]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> String.downcase()
    |> String.contains?(query)
  end

  defp matches_filter?(_value, "all"), do: true
  defp matches_filter?(value, filter), do: value == filter

  defp matches_status_filter?(status, "needs_attention"), do: status in ["failed", "verifying"]
  defp matches_status_filter?(status, filter), do: matches_filter?(status, filter)

  defp assign_transaction_selection(socket, selected_ids) do
    selectable_ids = socket.assigns.selectable_transaction_ids
    selected_ids = MapSet.intersection(selected_ids, selectable_ids)
    selected_count = MapSet.size(selected_ids)
    selectable_count = MapSet.size(selectable_ids)

    selected_ignored_count =
      Enum.count(socket.assigns.statement.bank_transactions, fn transaction ->
        transaction.status == "ignored" and MapSet.member?(selected_ids, transaction.id)
      end)

    # Keep checkbox events out of the page render. Only this small component
    # gets a DOM patch and synchronizes the native form controls in the same update.
    if connected?(socket) do
      send_update(NilaWeb.Banking.SelectionToolbarComponent,
        id: "banking-selection",
        selected_ids: Enum.to_list(selected_ids),
        selected_count: selected_count,
        selected_active_count: selected_count - selected_ignored_count,
        selected_ignored_count: selected_ignored_count
      )
    end

    socket
    |> assign(:selected_transaction_ids, selected_ids)
    |> assign(:selected_ignored_count, selected_ignored_count)
    |> assign(:selected_active_count, selected_count - selected_ignored_count)
    |> assign(
      :all_transactions_selected,
      selectable_count > 0 and selected_count == selectable_count
    )
  end

  defp applicable_ignore_action_ids(statement, ids, action) do
    ids = MapSet.new(ids)

    statement.bank_transactions
    |> Enum.filter(fn transaction ->
      MapSet.member?(ids, transaction.id) and
        case action do
          "ignore" -> transaction.status != "ignored"
          "restore" -> transaction.status == "ignored"
        end
    end)
    |> Enum.map(& &1.id)
  end

  defp toggle_id(ids, id) do
    if MapSet.member?(ids, id), do: MapSet.delete(ids, id), else: MapSet.put(ids, id)
  end

  defp selectable_transaction?(transaction),
    do: transaction.status not in ["queued", "posted", "verifying"]

  defp positive_integer(value) when is_integer(value) and value > 0, do: value

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> id
      _ -> nil
    end
  end

  defp positive_integer(_value), do: nil
  defp org_id(socket), do: socket.assigns.current_scope.current_org.id

  defp ledger_options(ledgers), do: Enum.map(ledgers, &{&1.name, &1.identity})

  defp status_filter_options do
    [
      {"All transactions", "all"},
      {"Needs ledger", "unassigned"},
      {"Ready to send", "ready"},
      {"Needs attention", "needs_attention"},
      {"In Tally", "posted"},
      {"Ignored", "ignored"}
    ]
  end

  defp transaction_view_tabs(socket, transactions, filters) do
    for {id, label, status} <- [
          {"needs-ledger", "Needs ledger", "unassigned"},
          {"ready-to-send", "Ready to send", "ready"},
          {"sent", "Sent", "posted"},
          {"all", "All", "all"}
        ] do
      tab_filters = Map.put(filters, "status", status)

      %{
        id: "banking-view-#{id}",
        label: label,
        value: status,
        count: transaction_view_count(transactions, status),
        patch: transaction_filter_path(socket, tab_filters)
      }
    end
  end

  defp transaction_review_tabs(socket, filters, group_count, individual_count) do
    for {id, label, review, count} <- [
          {"suggested-groups", "Suggested groups", "groups", group_count},
          {"individual-transactions", "Individual transactions", "individual", individual_count}
        ] do
      %{
        id: "banking-review-#{id}",
        label: label,
        value: review,
        count: count,
        patch: transaction_filter_path(socket, Map.put(filters, "review", review))
      }
    end
  end

  defp transaction_view_count(transactions, "all"), do: length(transactions)

  defp transaction_view_count(transactions, status),
    do: Enum.count(transactions, &(&1.status == status))

  defp transaction_empty_message(0, _filters), do: "No transactions were extracted."

  defp transaction_empty_message(_count, %{"query" => query, "type" => type})
       when query != "" or type != "all",
       do: "No transactions match these filters."

  defp transaction_empty_message(_count, %{"status" => "unassigned"}),
    do: "All transactions have ledgers."

  defp transaction_empty_message(_count, %{"status" => "ready"}),
    do: "No transactions are ready to send."

  defp transaction_empty_message(_count, %{"status" => "posted"}),
    do: "No transactions have been sent to Tally."

  defp transaction_empty_message(_count, _filters), do: "No transactions match this view."

  defp status_label("unassigned"), do: "Needs ledger"
  defp status_label("ready"), do: "Ready to send"
  defp status_label("queued"), do: "Sending"
  defp status_label("posted"), do: "In Tally"
  defp status_label("failed"), do: "Send failed"
  defp status_label("verifying"), do: "Confirmation pending"
  defp status_label("ignored"), do: "Ignored"

  defp type_filter_options do
    [{"All types", "all"} | Enum.map(Transaction.types(), &{humanize_type(&1), &1})]
  end

  defp humanize_type(value) when is_binary(value) do
    value |> String.replace("_", " ") |> String.capitalize()
  end

  defp status_variant("posted"), do: "success"
  defp status_variant("failed"), do: "error"
  defp status_variant("verifying"), do: "warning"
  defp status_variant("ready"), do: "info"
  defp status_variant("queued"), do: "accent"
  defp status_variant(_status), do: "neutral"

  defp money(paise), do: Nila.Formatters.format_money_with_paise(paise, prefix: "₹")

  defp transaction_amount(transaction) do
    if transaction.withdrawal_paise != 0,
      do: transaction.withdrawal_paise,
      else: transaction.deposit_paise
  end

  defp transaction_cash_direction(transaction) do
    if transaction.withdrawal_paise != 0,
      do: cash_direction(:withdrawal, transaction.withdrawal_paise),
      else: cash_direction(:deposit, transaction.deposit_paise)
  end

  defp cash_direction(:withdrawal, amount) when amount > 0, do: :outflow
  defp cash_direction(:withdrawal, amount) when amount < 0, do: :inflow
  defp cash_direction(:deposit, amount) when amount > 0, do: :inflow
  defp cash_direction(:deposit, amount) when amount < 0, do: :outflow
  defp cash_direction(_column, _amount), do: :zero

  defp statement_title(statement) do
    bank = Banking.bank_name(statement.bank_code) || "Bank"

    if statement.account_number_masked,
      do: "#{bank} · #{statement.account_number_masked}",
      else: "#{bank} statement"
  end

  defp failure_title(%{error: "We couldn’t identify the bank or statement layout." <> _rest}),
    do: "This statement format isn’t supported yet"

  defp failure_title(_statement), do: "Statement could not be read"

  defp statement_context(statement, transaction_count) do
    [
      statement.client.name,
      statement_period(statement),
      if(statement.status == "ready", do: transaction_count_text(transaction_count))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp statement_period(%{statement_from: %Date{} = from, statement_to: %Date{} = to}) do
    "#{format_display_date(from)}–#{format_display_date(to)}"
  end

  defp statement_period(_statement), do: nil

  defp transaction_count_text(1), do: "1 transaction"
  defp transaction_count_text(count), do: "#{count} transactions"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={assigns[:current_path]}>
      <div id="banking-statement-page" class="space-y-section">
        <.page_header
          eyebrow="Banking"
          eyebrow_path={~p"/banking"}
          title={statement_title(@statement)}
        >
          {statement_context(@statement, @transaction_count)}
        </.page_header>

        <.card
          :if={@statement.status in ["received", "extracting"]}
          id="banking-statement-processing"
          padding="roomy"
        >
          <div class="flex items-start gap-3">
            <.spinner tone="accent" label="Reading statement" />
            <div>
              <h2 class="text-base-content text-h4 font-semibold">Reading the statement</h2>

              <p class="text-body text-ink-muted mt-1">
                Nila is extracting the embedded text and checking the running balance. No OCR is used.
              </p>
            </div>
          </div>
        </.card>

        <div :if={@statement.status == "failed"} id="banking-statement-failed">
          <.callout kind="error" title={failure_title(@statement)}>
            {@statement.error}
          </.callout>
        </div>

        <.button
          :if={@statement.status == "failed"}
          navigate={~p"/banking"}
          id="banking-try-another"
          variant="outline"
          size="sm"
        >
          <.icon name="hero-arrow-path" class="size-4" /> Try another PDF
        </.button>

        <%= if @statement.status == "ready" do %>
          <div
            :if={not @running_balances_match}
            id="banking-balance-check-failed"
          >
            <.callout kind="error" title="Balances could not be verified">
              The saved transaction sequence and statement totals could not be reconciled.
              Sending to Tally is blocked. Check the source statement before continuing.
            </.callout>
          </div>

          <section id="banking-transactions" class="space-y-related">
            <div class="flex items-end justify-between gap-4">
              <div>
                <h2 class="text-base-content text-h4 font-semibold">Extracted transactions</h2>

                <p id="banking-visible-transaction-count" class="text-ink-muted text-ui mt-1">
                  <%= if @visible_transaction_count == @transaction_count do %>
                    {transaction_count_text(@transaction_count)}
                  <% else %>
                    {@visible_transaction_count} of {@transaction_count} transactions shown
                  <% end %>
                </p>
              </div>
            </div>

            <div id="banking-tally-setup">
              <div :if={is_nil(@tally_company)}>
                <.callout kind="warning" size="compact" title="Tally company not connected">
                  Connect {@statement.client.name} to a Tally company from Clients.
                </.callout>
              </div>

              <.form
                :if={not is_nil(@tally_company) and not @tally_destination_locked}
                for={@tally_setup_form}
                id="banking-tally-setup-form"
                phx-submit="configure-tally"
                class="bg-base-100 border-base-300 rounded-box grid gap-3 border p-3 lg:grid-cols-[minmax(0,1fr)_minmax(0,18rem)_auto] lg:items-end"
              >
                <div class="pb-1 lg:pr-3">
                  <p class="text-base-content text-ui font-semibold">Tally destination</p>

                  <p id="banking-tally-company" class="text-ink-muted text-ui">
                    {@tally_company.name}
                  </p>
                </div>

                <.input
                  field={@tally_setup_form[:bank_ledger_identity]}
                  type="select"
                  label="Bank ledger"
                  prompt="Choose synced ledger"
                  options={ledger_options(@tally_bank_ledgers)}
                />
                <.button
                  type="submit"
                  id="banking-save-tally-destination"
                  disabled={not @can_edit}
                  size="sm"
                >
                  Save
                </.button>
              </.form>

              <div
                :if={not is_nil(@tally_company) and @tally_destination_locked}
                id="banking-tally-setup-locked"
                class="bg-base-100 border-base-300 rounded-box grid gap-3 border p-3 lg:grid-cols-[minmax(0,1fr)_minmax(0,18rem)_auto] lg:items-center"
              >
                <div class="lg:pr-3">
                  <p class="text-base-content text-ui font-semibold">Tally destination</p>
                  <p id="banking-tally-company" class="text-ink-muted text-ui">
                    {@tally_company.name}
                  </p>
                </div>

                <div>
                  <p class="text-base-content text-ui font-semibold">Bank ledger</p>
                  <p class="text-ink-muted text-ui">{@statement.bank_ledger_name}</p>
                </div>

                <div class="lg:max-w-64">
                  <p class="text-base-content text-ui font-semibold">Destination locked</p>
                  <p class="text-ink-muted text-ui">
                    {tally_destination_lock_detail(@statement)}
                  </p>
                </div>
              </div>
            </div>

            <.navigation_tabs
              id="banking-transaction-views"
              items={@transaction_view_tabs}
              selected={@transaction_filters["status"]}
              label="Transaction views"
              controls="banking-transaction-rows"
            />

            <.navigation_tabs
              :if={@transaction_filters["status"] == "unassigned"}
              id="banking-review-modes"
              items={@transaction_review_tabs}
              selected={@transaction_filters["review"]}
              label="Needs ledger review mode"
              controls="banking-transaction-rows"
            />

            <.form
              for={@transaction_filter_form}
              id="banking-transaction-filters"
              phx-change="filter-transactions"
              class="grid gap-3 lg:grid-cols-[minmax(18rem,1fr)_minmax(0,14rem)]"
            >
              <.input
                field={@transaction_filter_form[:query]}
                type="search"
                label="Search transactions"
                placeholder="Narration, reference or ledger"
                phx-debounce="250"
              />
              <.input
                field={@transaction_filter_form[:type]}
                type="select"
                label="Transaction type"
                options={type_filter_options()}
              />
            </.form>

            <.form
              for={@transaction_form}
              id="banking-transaction-form"
              phx-submit="bank-transactions"
              phx-hook=".TransactionSelection"
            >
              <script :type={Phoenix.LiveView.ColocatedHook} name=".TransactionSelection">
                export default {
                  mounted() {
                    this.selectedIds = new Set()
                    this.handleEvent("banking-selection", ({ids}) => {
                      this.selectedIds = new Set(ids.map(String))
                      this.syncSelection()
                    })
                  },
                  updated() { this.syncSelection() },
                  syncSelection() {
                    let selectableCount = 0
                    let selectedCount = 0
                    this.el.querySelectorAll("[data-transaction-selection]").forEach(input => {
                      input.checked = !input.disabled && this.selectedIds.has(input.value)
                      if (!input.disabled) selectableCount++
                      if (input.checked) selectedCount++
                    })
                    const header = this.el.querySelector("#banking-select-all-transactions")
                    if (!header) return
                    header.checked = selectableCount > 0 && selectedCount === selectableCount
                    header.indeterminate = selectedCount > 0 && selectedCount < selectableCount
                    header.dataset.indeterminate = String(header.indeterminate)
                    header.setAttribute("aria-label", header.checked
                      ? "Clear filtered transaction selection"
                      : "Select all filtered transactions")
                  }
                }
              </script>

              <.data_table
                :if={
                  @transaction_filters["status"] == "unassigned" and
                    @transaction_filters["review"] == "groups"
                }
                id="banking-suggested-group-rows"
                rows={@transaction_group_rows}
                row_id={&transaction_row_dom_id/1}
                empty?={@transaction_group_count == 0}
                mode="review"
                min_width="min-w-[920px]"
                surface="workbench"
                detail_for={
                  fn row ->
                    MapSet.member?(@expanded_transaction_groups, row.group.key)
                  end
                }
              >
                <:col :let={row} key="suggestion" label="Suggestion / evidence" row_header>
                  <% expanded? =
                    MapSet.member?(@expanded_transaction_groups, row.group.key) %>
                  <.row_disclosure
                    id={"banking-transaction-group-toggle-#{row.group.key}"}
                    expanded={expanded?}
                    label={
                      if expanded?,
                        do: "Hide transactions for #{row.group.payee}",
                        else: "Show transactions for #{row.group.payee}"
                    }
                    phx-click="toggle-transaction-group"
                    phx-value-key={row.group.key}
                  >
                    <:title>{row.group.payee}</:title>
                    <:detail>{transaction_group_detail(row.group)}</:detail>
                  </.row_disclosure>
                </:col>

                <:col
                  :let={row}
                  key="coverage"
                  label="Coverage"
                  align="right"
                  class="whitespace-nowrap"
                >
                  <span class="text-base-content font-semibold">
                    {transaction_group_coverage(row.group)}
                  </span>
                </:col>

                <:col :let={row} key="ledger" label="Ledger">
                  <% context = {:review_group, row.group.key} %>
                  <% ledger = Map.get(@review_ledger_selections, context) %>
                  <.picker_trigger
                    id={"banking-transaction-group-ledger-#{row.group.key}"}
                    phx-click="open-transaction-group-ledger-picker"
                    phx-value-key={row.group.key}
                    popovertarget="banking-ledger-picker"
                    placeholder={is_nil(ledger)}
                    title={if ledger, do: ledger.name, else: "Choose ledger"}
                    disabled={
                      not @can_edit or @tally_ledgers == [] or
                        not is_integer(@statement.tally_company_id) or
                        not is_binary(@statement.bank_ledger_identity)
                    }
                  >
                    {if ledger, do: ledger.name, else: "Choose ledger"}
                  </.picker_trigger>
                </:col>

                <:col :let={row} key="action" label="Action" class="whitespace-nowrap">
                  <% context = {:review_group, row.group.key} %>
                  <.button
                    class="whitespace-nowrap"
                    type="button"
                    id={"banking-transaction-group-apply-#{row.group.key}"}
                    phx-click="apply-transaction-group"
                    phx-value-key={row.group.key}
                    disabled={
                      row.group.included_count == 0 or
                        is_nil(Map.get(@review_ledger_selections, context))
                    }
                  >
                    Assign {row.group.included_count}
                  </.button>
                </:col>

                <:detail :let={row}>
                  <div class="bg-base-200/50 p-3">
                    <.data_table
                      id={"banking-transaction-group-detail-#{row.group.key}"}
                      rows={
                        transaction_group_detail_rows(
                          @fully_expanded_transaction_groups,
                          row.group
                        )
                      }
                      row_id={&transaction_row_dom_id/1}
                      mode="review"
                      surface="evidence"
                      min_width="min-w-[760px]"
                    >
                      <:col :let={member} key="include" label="Include">
                        <.input
                          type="checkbox"
                          id={"banking-transaction-group-member-select-#{member.transaction.id}"}
                          checkbox_hit_area="large"
                          name={"transaction_group_members[#{member.group_key}][]"}
                          checkbox_value={member.transaction.id}
                          checked={member.included}
                          hidden_input={false}
                          disabled={not @can_edit}
                          phx-click="toggle-transaction-group-member"
                          phx-value-key={member.group_key}
                          phx-value-id={member.transaction.id}
                          aria-label={
                            "Include transaction from #{format_display_date(member.transaction.date)}"
                          }
                        />
                      </:col>
                      <:col :let={member} key="date" label="Date" class="whitespace-nowrap">
                        {format_display_date(member.transaction.date)}
                      </:col>
                      <:col
                        :let={member}
                        key="narration"
                        label="Narration"
                        class="max-w-3xl"
                        row_header
                      >
                        <span class="text-base-content">{member.transaction.narration}</span>
                      </:col>
                      <:col
                        :let={member}
                        key="amount"
                        label="Amount"
                        align="right"
                        class="whitespace-nowrap"
                      >
                        <span
                          data-cash-direction={transaction_cash_direction(member.transaction)}
                          class="nila-bank-cash-amount"
                        >
                          {money(transaction_amount(member.transaction))}
                        </span>
                      </:col>
                      <:col
                        :let={member}
                        key="reference"
                        label="Chq. / Ref."
                        class="whitespace-nowrap"
                      >
                        {member.transaction.reference || "—"}
                      </:col>
                    </.data_table>

                    <div
                      :if={
                        row.group.count > transaction_group_preview_limit() and
                          not MapSet.member?(
                            @fully_expanded_transaction_groups,
                            row.group.key
                          )
                      }
                      class="pt-2"
                    >
                      <.button
                        type="button"
                        id={"banking-transaction-group-show-all-#{row.group.key}"}
                        variant="ghost"
                        size="xs"
                        phx-click="show-all-transaction-group"
                        phx-value-key={row.group.key}
                        aria-label={"Show all #{row.group.count} transactions"}
                      >
                        Show remaining {row.group.count - transaction_group_preview_limit()} transactions
                      </.button>
                    </div>
                  </div>
                </:detail>

                <:empty>No suggested groups match these filters.</:empty>
              </.data_table>

              <.data_table
                :if={
                  @transaction_filters["status"] != "unassigned" or
                    @transaction_filters["review"] == "individual"
                }
                id="banking-transaction-rows"
                rows={@streams.transaction_rows}
                empty?={
                  cond do
                    @transaction_filters["status"] != "unassigned" ->
                      @visible_transaction_count == 0

                    @transaction_filters["review"] == "groups" ->
                      @transaction_group_count == 0

                    true ->
                      @visible_individual_count == 0
                  end
                }
                mode="review"
                surface="workbench"
                min_width={
                  if @transaction_filters["status"] == "unassigned" and
                       @transaction_filters["review"] == "groups",
                     do: "min-w-[920px]",
                     else: "min-w-[1120px]"
                }
              >
                <:col_header
                  :if={
                    @transaction_filters["status"] != "unassigned" or
                      @transaction_filters["review"] == "individual"
                  }
                  column="selection"
                >
                  <.input
                    type="checkbox"
                    id="banking-select-all-transactions"
                    checkbox_hit_area="large"
                    name="select_all_transactions"
                    hidden_input={false}
                    disabled={MapSet.size(@selectable_transaction_ids) == 0}
                    phx-click="toggle-all-transactions"
                    aria-label="Select all filtered transactions"
                  />
                </:col_header>

                <:col
                  :let={row}
                  :if={
                    @transaction_filters["status"] != "unassigned" or
                      @transaction_filters["review"] == "individual"
                  }
                  key="selection"
                  label="Select"
                >
                  <% transaction = row.transaction %>
                  <.input
                    type="checkbox"
                    id={"banking-select-transaction-#{transaction.id}"}
                    checkbox_hit_area="large"
                    data-transaction-selection
                    name="transaction_ids[]"
                    checkbox_value={transaction.id}
                    hidden_input={false}
                    disabled={not @can_edit or not selectable_transaction?(transaction)}
                    phx-click="toggle-transaction"
                    phx-value-id={transaction.id}
                    aria-label={"Select transaction from #{format_display_date(transaction.date)}"}
                  />
                </:col>

                <:col
                  :let={row}
                  :if={
                    @transaction_filters["status"] != "unassigned" or
                      @transaction_filters["review"] == "individual"
                  }
                  label="Date"
                  class="whitespace-nowrap"
                >
                  <span :if={transaction = row_transaction(row)}>
                    {format_display_date(transaction.date)}
                  </span>
                </:col>

                <:col
                  :let={row}
                  label="Narration"
                  class="max-w-3xl"
                  row_header
                >
                  <% transaction = row.transaction %>
                  <span class="text-base-content">{transaction.narration}</span>
                  <span :if={transaction.error} class="text-error text-ui mt-1 block">
                    {transaction.error["message"] || "Tally could not post this transaction."}
                  </span>
                </:col>

                <:col
                  :let={row}
                  :if={
                    @transaction_filters["status"] != "unassigned" or
                      @transaction_filters["review"] == "individual"
                  }
                  label="Type"
                  class="whitespace-nowrap"
                >
                  {humanize_type(row.transaction.transaction_type)}
                </:col>

                <:col
                  :let={row}
                  label="Amount"
                  align="right"
                  class="whitespace-nowrap"
                >
                  <% transaction = row.transaction %>
                  <span
                    data-cash-direction={transaction_cash_direction(transaction)}
                    class="nila-bank-cash-amount"
                  >
                    {money(transaction_amount(transaction))}
                  </span>
                </:col>

                <:col :let={row} label="Ledger">
                  <% transaction = row.transaction %>
                  <%= if @transaction_filters["status"] == "unassigned" do %>
                    <% context = {:review_transaction, transaction.id} %>
                    <% ledger = Map.get(@review_ledger_selections, context) %>
                    <.picker_trigger
                      id={"banking-ledger-trigger-#{transaction.id}"}
                      phx-click="open-review-transaction-ledger-picker"
                      phx-value-id={transaction.id}
                      popovertarget="banking-ledger-picker"
                      placeholder={is_nil(ledger)}
                      title={if ledger, do: ledger.name, else: "Choose ledger"}
                      disabled={
                        not @can_edit or @tally_ledgers == [] or
                          not is_integer(@statement.tally_company_id) or
                          not is_binary(@statement.bank_ledger_identity) or
                          not selectable_transaction?(transaction)
                      }
                    >
                      {if ledger, do: ledger.name, else: "Choose ledger"}
                    </.picker_trigger>
                  <% else %>
                    <.picker_trigger
                      id={"banking-ledger-trigger-#{transaction.id}"}
                      phx-click="open-ledger-picker"
                      phx-value-id={transaction.id}
                      popovertarget="banking-ledger-picker"
                      placeholder={is_nil(transaction.counter_ledger_name)}
                      title={transaction.counter_ledger_name || "Choose ledger"}
                      disabled={
                        not @can_edit or @tally_ledgers == [] or
                          not is_integer(@statement.tally_company_id) or
                          not is_binary(@statement.bank_ledger_identity) or
                          not selectable_transaction?(transaction)
                      }
                    >
                      {transaction.counter_ledger_name || "Choose ledger"}
                    </.picker_trigger>
                  <% end %>
                </:col>

                <:col
                  :let={row}
                  label={
                    if @transaction_filters["status"] == "unassigned",
                      do: "Action",
                      else: "Status"
                  }
                  class="whitespace-nowrap"
                >
                  <% transaction = row.transaction %>
                  <%= if @transaction_filters["status"] == "unassigned" do %>
                    <.button
                      type="button"
                      id={"banking-review-transaction-apply-#{transaction.id}"}
                      variant="outline"
                      phx-click="apply-review-transaction"
                      phx-value-id={transaction.id}
                      disabled={
                        is_nil(
                          Map.get(
                            @review_ledger_selections,
                            {:review_transaction, transaction.id}
                          )
                        )
                      }
                    >
                      Apply
                    </.button>
                  <% else %>
                    <.badge variant={status_variant(transaction.status)}>
                      {status_label(transaction.status)}
                    </.badge>
                  <% end %>
                </:col>

                <:col
                  :let={row}
                  :if={
                    @transaction_filters["status"] != "unassigned" or
                      @transaction_filters["review"] == "individual"
                  }
                  label="Chq. / Ref."
                >
                  <span :if={transaction = row_transaction(row)}>
                    {transaction.reference || "—"}
                  </span>
                </:col>

                <:col
                  :let={row}
                  :if={
                    @transaction_filters["status"] != "unassigned" or
                      @transaction_filters["review"] == "individual"
                  }
                  label="Balance"
                  align="right"
                >
                  <span :if={transaction = row_transaction(row)}>
                    {money(transaction.balance_paise)}
                  </span>
                </:col>

                <:empty>
                  <%= if @transaction_filters["status"] == "unassigned" and
                         @transaction_filters["review"] == "groups" do %>
                    No suggested groups match these filters.
                  <% else %>
                    {transaction_empty_message(@transaction_count, @transaction_filters)}
                  <% end %>
                </:empty>
              </.data_table>
            </.form>

            <.select_panel
              id="banking-ledger-picker"
              title={ledger_picker_title(@ledger_picker_transaction_id)}
              filter_value={@ledger_filter_form[:query].value || ""}
            >
              <:search>
                <.form
                  for={@ledger_filter_form}
                  id="banking-ledger-filter-form"
                  phx-change="filter-ledger-picker"
                  phx-submit="select-ledger-by-query"
                >
                  <.input
                    field={@ledger_filter_form[:query]}
                    type="search"
                    placeholder="Search Tally ledgers"
                    aria-label="Search Tally ledgers"
                    aria-controls="banking-ledger-options"
                    autocomplete="off"
                    phx-debounce="200"
                    data-selectable-input
                  />
                </.form>
              </:search>

              <.selectable_listbox id="banking-ledger-options" label="Tally ledgers">
                <p
                  :if={@ledger_picker_transaction_id && @ledger_picker_options == []}
                  id="banking-ledger-options-empty"
                  class="text-ink-muted text-ui px-3 py-6 text-center"
                >
                  No ledgers match this search.
                </p>

                <p
                  :if={is_nil(@ledger_picker_transaction_id)}
                  class="text-ink-muted text-ui px-3 py-6 text-center"
                >
                  Loading ledgers…
                </p>

                <.selectable_option
                  :for={ledger <- @ledger_picker_options}
                  id={ledger_option_dom_id(ledger)}
                  selected={ledger.identity == @ledger_picker_selected_identity}
                  phx-click="select-ledger"
                  phx-value-identity={ledger.identity}
                  popovertarget="banking-ledger-picker"
                  popovertargetaction="hide"
                >
                  {ledger.name}
                  <:meta :if={ledger_parent(ledger)}>{ledger_parent(ledger)}</:meta>
                </.selectable_option>
              </.selectable_listbox>
            </.select_panel>
          </section>
        <% end %>
      </div>

      <:bottom_bar>
        <.live_component
          module={NilaWeb.Banking.SelectionToolbarComponent}
          id="banking-selection"
          can_edit={@can_edit}
          balance_check_passed={@running_balances_match}
          ledger_configured={
            is_integer(@statement.tally_company_id) and
              is_binary(@statement.bank_ledger_identity) and @tally_ledgers != []
          }
          bulk_ledger={@bulk_ledger}
        />
      </:bottom_bar>
    </Layouts.app>
    """
  end
end
