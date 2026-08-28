defmodule NilaWeb.Banking.StatementLive do
  use NilaWeb, :live_view

  alias Nila.Accounts.Policy
  alias Nila.Banking
  alias Nila.Banking.Transaction
  alias Nila.TallyJobs

  @impl true
  def mount(%{"id" => id}, _session, socket) do
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
         |> assign_statement(statement)}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Bank statement not found")
         |> push_navigate(to: ~p"/banking")}
    end
  end

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

      _ ->
        {:noreply,
         put_flash(socket, :error, "Connect the client to Tally and choose a bank ledger.")}
    end
  end

  def handle_event("filter-transactions", %{"transaction_filters" => params}, socket) do
    filters = normalize_transaction_filters(params)

    {:noreply,
     assign_filtered_transactions(
       socket,
       socket.assigns.statement.bank_transactions,
       filters,
       socket.assigns.selected_transaction_ids
     )}
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
    case active_ledger_transaction(socket) do
      :bulk ->
        {:noreply, assign_ledger_picker(socket, :bulk, Map.get(params, "query", ""))}

      %Transaction{} = transaction ->
        {:noreply, assign_ledger_picker(socket, transaction, Map.get(params, "query", ""))}

      nil ->
        {:noreply, socket}
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
    filters = socket.assigns[:transaction_filters] || default_transaction_filters()

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

  defp active_ledger_transaction(socket) do
    case socket.assigns.ledger_picker_transaction_id do
      :bulk -> if bulk_ledger_available?(socket.assigns), do: :bulk
      id when is_integer(id) -> transaction_by_id(socket, id)
      nil -> nil
    end
  end

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

    selectable_transaction_ids =
      visible_transactions
      |> Enum.filter(&(socket.assigns.can_edit and selectable_transaction?(&1)))
      |> MapSet.new(& &1.id)

    socket
    |> assign(:transaction_filters, filters)
    |> assign(:transaction_filter_form, to_form(filters, as: :transaction_filters))
    |> assign(:visible_transaction_count, length(visible_transactions))
    |> assign(:selectable_transaction_ids, selectable_transaction_ids)
    |> assign_transaction_selection(selected_ids)
    |> stream(:transactions, visible_transactions,
      reset: true,
      dom_id: fn transaction -> "bank-transaction-#{transaction.id}" end
    )
  end

  defp default_transaction_filters,
    do: %{"query" => "", "status" => "all", "type" => "all"}

  defp normalize_transaction_filters(params) do
    %{
      "query" => params |> Map.get("query", "") |> String.trim(),
      "status" =>
        valid_filter(Map.get(params, "status"), Enum.map(status_filter_options(), &elem(&1, 1))),
      "type" => valid_filter(Map.get(params, "type"), Transaction.types())
    }
  end

  defp valid_filter(value, allowed), do: if(value in allowed, do: value, else: "all")

  defp filter_transactions(transactions, filters) do
    query = String.downcase(filters["query"])

    Enum.filter(transactions, fn transaction ->
      matches_transaction_query?(transaction, query) and
        matches_status_filter?(transaction.status, filters["status"]) and
        matches_filter?(transaction.transaction_type, filters["type"])
    end)
  end

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
          <.callout kind="error" title="Statement could not be read">
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
                :if={not is_nil(@tally_company)}
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
            </div>

            <.form
              for={@transaction_filter_form}
              id="banking-transaction-filters"
              phx-change="filter-transactions"
              class="grid gap-3 lg:grid-cols-[minmax(18rem,1fr)_minmax(0,14rem)_minmax(0,14rem)]"
            >
              <.input
                field={@transaction_filter_form[:query]}
                type="search"
                label="Search transactions"
                placeholder="Narration, reference or ledger"
                phx-debounce="250"
              />
              <.input
                field={@transaction_filter_form[:status]}
                type="select"
                label="Status"
                options={status_filter_options()}
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
                id="banking-transaction-rows"
                rows={@streams.transactions}
                empty?={@visible_transaction_count == 0}
                mode="scan"
                min_width="min-w-[1100px]"
              >
                <:col_header column="selection">
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

                <:col :let={transaction} key="selection" label="Select">
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

                <:col :let={transaction} label="Date" class="whitespace-nowrap">
                  {format_display_date(transaction.date)}
                </:col>

                <:col :let={transaction} label="Narration" class="max-w-xl" row_header>
                  <span class="text-base-content">{transaction.narration}</span>
                  <span :if={transaction.error} class="text-error text-ui mt-1 block">
                    {transaction.error["message"] || "Tally could not post this transaction."}
                  </span>
                </:col>

                <:col :let={transaction} label="Type" class="whitespace-nowrap">
                  {humanize_type(transaction.transaction_type)}
                </:col>

                <:col :let={transaction} label="Amount" align="right">
                  <span
                    data-cash-direction={transaction_cash_direction(transaction)}
                    class="nila-bank-cash-amount"
                  >
                    {money(transaction_amount(transaction))}
                  </span>
                </:col>

                <:col :let={transaction} label="Ledger">
                  <.picker_trigger
                    id={"banking-ledger-trigger-#{transaction.id}"}
                    phx-click="open-ledger-picker"
                    phx-value-id={transaction.id}
                    popovertarget="banking-ledger-picker"
                    popovertargetaction="show"
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
                </:col>

                <:col :let={transaction} label="Status">
                  <.badge variant={status_variant(transaction.status)}>
                    {status_label(transaction.status)}
                  </.badge>
                </:col>

                <:col :let={transaction} label="Chq. / Ref.">
                  {transaction.reference || "—"}
                </:col>

                <:col :let={transaction} label="Balance" align="right">
                  {money(transaction.balance_paise)}
                </:col>

                <:empty>
                  {if @transaction_count == 0,
                    do: "No transactions were extracted.",
                    else: "No transactions match these filters."}
                </:empty>
              </.data_table>
            </.form>

            <.select_panel
              id="banking-ledger-picker"
              title={
                if @ledger_picker_transaction_id == :bulk,
                  do: "Ledger for selected transactions",
                  else: "Choose ledger"
              }
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
