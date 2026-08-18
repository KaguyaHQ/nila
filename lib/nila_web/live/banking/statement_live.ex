defmodule NilaWeb.Banking.StatementLive do
  use NilaWeb, :live_view

  alias Nila.Banking

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    org = socket.assigns.current_scope.current_org

    case Banking.get_statement(org.id, id) do
      {:ok, statement} ->
        if connected?(socket), do: Banking.subscribe(org.id)

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

  @impl true
  def handle_info({:bank_statement_progress, statement_id, _state}, socket)
      when statement_id == socket.assigns.statement.id do
    org_id = socket.assigns.current_scope.current_org.id

    case Banking.get_statement(org_id, statement_id) do
      {:ok, statement} -> {:noreply, assign_statement(socket, statement)}
      {:error, :not_found} -> {:noreply, push_navigate(socket, to: ~p"/banking")}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp assign_statement(socket, statement) do
    transactions = if statement.status == "ready", do: statement.transactions, else: []

    socket
    |> assign(:statement, statement)
    |> assign(:transaction_count, length(transactions))
    |> assign(:export_form, export_form(statement))
    |> stream(:transactions, transactions,
      reset: true,
      dom_id: fn transaction -> "bank-transaction-#{transaction["id"]}" end
    )
  end

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

            <.data_table
              id="banking-transaction-rows"
              rows={@streams.transactions}
              empty?={@transaction_count == 0}
              mode="scan"
              min_width="min-w-[1040px]"
            >
              <:col :let={transaction} label="Date">
                {format_display_date(transaction["date"])}
              </:col>
              <:col :let={transaction} label="Narration" class="max-w-xl" row_header>
                <span class="text-base-content">{transaction["narration"]}</span>
              </:col>
              <:col :let={transaction} label="Chq. / Ref.">
                {transaction["reference"] || "—"}
              </:col>
              <:col :let={transaction} label="Withdrawal" align="right">
                <span
                  data-cash-direction={cash_direction(:withdrawal, transaction["withdrawal_paise"])}
                  class="nila-bank-cash-amount"
                >
                  {money(transaction["withdrawal_paise"])}
                </span>
              </:col>
              <:col :let={transaction} label="Deposit" align="right">
                <span
                  data-cash-direction={cash_direction(:deposit, transaction["deposit_paise"])}
                  class="nila-bank-cash-amount"
                >
                  {money(transaction["deposit_paise"])}
                </span>
              </:col>
              <:col :let={transaction} label="Balance" align="right">
                {money(transaction["balance_paise"])}
              </:col>
              <:empty>No transactions were extracted.</:empty>
            </.data_table>
          </section>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
