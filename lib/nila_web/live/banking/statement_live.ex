defmodule NilaWeb.Banking.StatementLive do
  use NilaWeb, :live_view

  alias Nila.Accounts.Policy
  alias Nila.Banking
  alias Nila.TallyDevices
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
  def handle_event("validate-export", %{"export" => params}, socket) do
    {:noreply, assign(socket, :export_form, to_form(params, as: :export))}
  end

  def handle_event("select-tally-company", %{"tally_setup" => params}, socket) do
    company_id = positive_integer(params["company_id"])

    bank_ledgers =
      if company_id, do: Banking.list_tally_bank_ledgers(org_id(socket), company_id), else: []

    {:noreply,
     socket
     |> assign(:selected_company_id, company_id)
     |> assign(:tally_bank_ledgers, bank_ledgers)
     |> assign(
       :tally_ledgers,
       if(company_id, do: Banking.list_tally_ledgers(org_id(socket), company_id), else: [])
     )
     |> assign(:tally_setup_form, to_form(params, as: :tally_setup))}
  end

  def handle_event("configure-tally", %{"tally_setup" => params}, socket) do
    with true <- Policy.can?(socket.assigns.current_scope, :edit_records),
         company_id when is_integer(company_id) <- positive_integer(params["company_id"]),
         ledger_identity when is_binary(ledger_identity) and ledger_identity != "" <-
           params["bank_ledger_identity"],
         {:ok, _statement} <-
           Banking.configure_tally(
             org_id(socket),
             socket.assigns.statement.id,
             company_id,
             ledger_identity
           ) do
      {:noreply, socket |> put_flash(:info, "Tally destination saved.") |> reload_statement()}
    else
      false -> {:noreply, put_flash(socket, :error, "You cannot change banking records.")}
      _ -> {:noreply, put_flash(socket, :error, "Choose an open Tally company and bank ledger.")}
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

  def handle_info(_message, socket), do: {:noreply, socket}

  defp assign_statement(socket, statement) do
    transactions = if statement.status == "ready", do: statement.bank_transactions, else: []
    companies = TallyDevices.list_open_companies(statement.org_id, statement.client_id)

    selected_company_id =
      statement.tally_company_id ||
        case companies do
          [company] -> company.id
          _ -> nil
        end

    ledgers =
      if selected_company_id,
        do: Banking.list_tally_ledgers(statement.org_id, selected_company_id),
        else: []

    bank_ledgers =
      if selected_company_id,
        do: Banking.list_tally_bank_ledgers(statement.org_id, selected_company_id),
        else: []

    socket
    |> assign(:statement, statement)
    |> assign(:can_edit, Policy.can?(socket.assigns.current_scope, :edit_records))
    |> assign(:transaction_count, length(transactions))
    |> assign(:tally_companies, companies)
    |> assign(:selected_company_id, selected_company_id)
    |> assign(:tally_ledgers, ledgers)
    |> assign(:tally_bank_ledgers, bank_ledgers)
    |> assign(:tally_setup_form, tally_setup_form(statement, selected_company_id))
    |> assign(:transaction_form, transaction_form())
    |> assign(:export_form, export_form(statement))
    |> stream(:transactions, transactions,
      reset: true,
      dom_id: fn transaction -> "bank-transaction-#{transaction.id}" end
    )
  end

  defp reload_statement(socket) do
    case Banking.get_statement(org_id(socket), socket.assigns.statement.id) do
      {:ok, statement} -> assign_statement(socket, statement)
      {:error, :not_found} -> push_navigate(socket, to: ~p"/banking")
    end
  end

  defp handle_transaction_action("map", ids, params, socket) do
    type = blank_to_nil(params["transaction_type"])

    case Banking.map_transactions(
           org_id(socket),
           socket.assigns.statement.id,
           ids,
           params["counter_ledger_identity"],
           type
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

      _ ->
        {:noreply, put_flash(socket, :error, "Tally is unavailable or the selection changed.")}
    end
  end

  defp handle_transaction_action(action, ids, _params, socket)
       when action in ["ignore", "restore"] do
    {:ok, transactions} =
      Banking.set_ignored(
        org_id(socket),
        socket.assigns.statement.id,
        ids,
        action == "ignore"
      )

    verb = if action == "ignore", do: "Ignored", else: "Restored"

    {:noreply,
     socket
     |> put_flash(:info, "#{verb} #{length(transactions)} transactions.")
     |> reload_statement()}
  end

  defp handle_transaction_action(_action, _ids, _params, socket),
    do: {:noreply, put_flash(socket, :error, "Choose an action.")}

  defp tally_setup_form(statement, selected_company_id) do
    to_form(
      %{
        "company_id" => selected_company_id,
        "bank_ledger_identity" => statement.bank_ledger_identity
      },
      as: :tally_setup
    )
  end

  defp transaction_form do
    to_form(%{"counter_ledger_identity" => "", "transaction_type" => ""},
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

  defp positive_integer(value) when is_integer(value) and value > 0, do: value

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> id
      _ -> nil
    end
  end

  defp positive_integer(_value), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
  defp org_id(socket), do: socket.assigns.current_scope.current_org.id

  defp ledger_options(ledgers), do: Enum.map(ledgers, &{&1.name, &1.identity})

  defp transaction_type_options do
    [
      {"Keep Payment / Receipt", ""},
      {"Payment", "payment"},
      {"Receipt", "receipt"},
      {"Contra withdrawal", "contra_withdrawal"},
      {"Contra deposit", "contra_deposit"}
    ]
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

  defp export_form(statement) do
    to_form(
      %{
        "bank_ledger_name" => statement.bank_ledger_name,
        "from" => iso(statement.statement_from),
        "to" => iso(statement.statement_to)
      },
      as: :export
    )
  end

  defp iso(%Date{} = date), do: Date.to_iso8601(date)
  defp iso(_date), do: ""

  defp money(paise), do: Nila.Formatters.format_money_with_paise(paise, prefix: "₹")

  defp cash_direction(:withdrawal, amount) when amount > 0, do: :outflow
  defp cash_direction(:withdrawal, amount) when amount < 0, do: :inflow
  defp cash_direction(:deposit, amount) when amount > 0, do: :inflow
  defp cash_direction(:deposit, amount) when amount < 0, do: :outflow
  defp cash_direction(_column, _amount), do: :zero

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={assigns[:current_path]}>
      <div id="banking-statement-page" class="space-y-section">
        <.page_header eyebrow="Banking" eyebrow_path={~p"/banking"} title={@statement.client.name}>
          {@statement.bank_name} statement
          <span :if={@statement.account_number_masked}> · {@statement.account_number_masked}</span>
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
          Try another PDF
        </.button>

        <%= if @statement.status == "ready" do %>
          <div id="banking-statement-summary" class="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
            <.stat_card label="Opening balance">
              {money(@statement.opening_balance_paise)}
            </.stat_card>
            <.stat_card label="Closing balance">
              {money(@statement.closing_balance_paise)}
            </.stat_card>
            <.stat_card label="Withdrawals">{money(@statement.total_withdrawal_paise)}</.stat_card>
            <.stat_card label="Deposits">{money(@statement.total_deposit_paise)}</.stat_card>
          </div>

          <.card id="banking-tally-setup" class="space-y-block">
            <div>
              <h2 class="text-base-content text-h4 font-semibold">Tally destination</h2>
              <p class="text-ink-muted text-ui mt-1">
                Choose the client-linked company and an actual bank ledger from its latest Tally sync.
              </p>
            </div>

            <div :if={@tally_companies == []}>
              <.callout kind="warning" title="No linked Tally company is open">
                Open this client's company in Tally, run Sync now in Nila Connector, and return here.
              </.callout>
            </div>

            <.form
              :if={@tally_companies != []}
              for={@tally_setup_form}
              id="banking-tally-setup-form"
              phx-change="select-tally-company"
              phx-submit="configure-tally"
              class="grid gap-3 lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)_auto] lg:items-end"
            >
              <.input
                field={@tally_setup_form[:company_id]}
                type="select"
                label="Tally company"
                prompt="Choose company"
                options={Enum.map(@tally_companies, &{&1.name, &1.id})}
              />
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
              >
                Save destination
              </.button>
            </.form>
          </.card>

          <.card id="banking-tally-export" class="space-y-block">
            <div class="gap-block flex flex-col lg:flex-row lg:items-start lg:justify-between">
              <div>
                <h2 class="text-base-content text-h4 font-semibold">Tally import</h2>
                <p class="text-ink-muted text-ui mt-1">
                  Creates Payment and Receipt vouchers against Suspense. The bank ledger must already exist in Tally.
                </p>
              </div>
              <.badge variant="success">
                {@transaction_count} transactions · balances reconcile
              </.badge>
            </div>

            <.form
              for={@export_form}
              id="banking-export-form"
              action={~p"/banking/#{@statement.id}/tally.xml"}
              method="get"
              phx-change="validate-export"
              class="grid gap-3 lg:grid-cols-[minmax(0,1fr)_minmax(0,13rem)_minmax(0,13rem)_auto] lg:items-end"
            >
              <.input
                field={@export_form[:bank_ledger_name]}
                label="Bank ledger name in Tally"
                required
              />
              <.input field={@export_form[:from]} type="date" label="From date" required />
              <.input field={@export_form[:to]} type="date" label="To date" required />
              <.button type="submit" id="banking-download-tally">
                <.icon name="hero-arrow-down-tray" class="size-4" /> Download Tally XML
              </.button>
            </.form>
          </.card>

          <section id="banking-transactions" class="space-y-related">
            <div class="flex items-end justify-between gap-4">
              <div>
                <h2 class="text-base-content text-h4 font-semibold">Extracted transactions</h2>
                <p class="text-ink-muted text-ui mt-1">
                  {format_display_date(@statement.statement_from)}–{format_display_date(
                    @statement.statement_to
                  )}
                </p>
              </div>
            </div>

            <.form
              for={@transaction_form}
              id="banking-transaction-form"
              phx-submit="bank-transactions"
              class="space-y-related"
            >
              <div
                :if={@can_edit}
                class="bg-base-200 gap-related rounded-box flex flex-wrap items-end p-3"
              >
                <label class="form-control min-w-64 flex-1">
                  <span class="label-text mb-1">Counter-ledger</span>
                  <select name="counter_ledger_identity" class="select select-bordered w-full">
                    <option value="">Choose synced ledger</option>
                    <option :for={ledger <- @tally_ledgers} value={ledger.identity}>
                      {ledger.name}
                    </option>
                  </select>
                </label>
                <label class="form-control min-w-52">
                  <span class="label-text mb-1">Transaction type</span>
                  <select name="transaction_type" class="select select-bordered w-full">
                    <option :for={{label, value} <- transaction_type_options()} value={value}>
                      {label}
                    </option>
                  </select>
                </label>
                <.button type="submit" name="action" value="map" variant="outline">
                  Assign selected
                </.button>
                <.button type="submit" name="action" value="ignore" variant="ghost">
                  Ignore
                </.button>
                <.button type="submit" name="action" value="restore" variant="ghost">
                  Restore
                </.button>
                <.button type="submit" name="action" value="send" id="banking-send-tally">
                  Send selected to Tally
                </.button>
              </div>

              <.data_table
                id="banking-transaction-rows"
                rows={@streams.transactions}
                empty?={@transaction_count == 0}
                mode="scan"
                min_width="min-w-[1240px]"
              >
                <:col :let={transaction} label="Select">
                  <input
                    type="checkbox"
                    name="transaction_ids[]"
                    value={transaction.id}
                    disabled={
                      not @can_edit or transaction.status in ["queued", "posted", "verifying"]
                    }
                    class="checkbox checkbox-sm"
                  />
                </:col>
                <:col :let={transaction} label="Date">
                  {format_display_date(transaction.date)}
                </:col>
                <:col :let={transaction} label="Narration" class="max-w-xl" row_header>
                  <span class="text-base-content">{transaction.narration}</span>
                  <span :if={transaction.error} class="text-error mt-1 block text-xs">
                    {transaction.error["message"] || "Tally could not post this transaction."}
                  </span>
                </:col>
                <:col :let={transaction} label="Ledger">
                  {transaction.counter_ledger_name || "Unassigned"}
                </:col>
                <:col :let={transaction} label="Type">
                  {humanize_type(transaction.transaction_type)}
                </:col>
                <:col :let={transaction} label="Status">
                  <.badge variant={status_variant(transaction.status)}>
                    {humanize_type(transaction.status)}
                  </.badge>
                </:col>
                <:col :let={transaction} label="Chq. / Ref.">
                  {transaction.reference || "—"}
                </:col>
                <:col :let={transaction} label="Withdrawal" align="right">
                  <span
                    data-cash-direction={cash_direction(:withdrawal, transaction.withdrawal_paise)}
                    class="nila-bank-cash-amount"
                  >
                    {money(transaction.withdrawal_paise)}
                  </span>
                </:col>
                <:col :let={transaction} label="Deposit" align="right">
                  <span
                    data-cash-direction={cash_direction(:deposit, transaction.deposit_paise)}
                    class="nila-bank-cash-amount"
                  >
                    {money(transaction.deposit_paise)}
                  </span>
                </:col>
                <:col :let={transaction} label="Balance" align="right">
                  {money(transaction.balance_paise)}
                </:col>
                <:empty>No transactions were extracted.</:empty>
              </.data_table>
            </.form>
          </section>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
