defmodule NilaWeb.BankLive do
  use NilaWeb, :live_view

  alias Nila.Banking

  @impl true
  def mount(_params, _session, socket) do
    accounts = list_accounts(socket)

    {:ok,
     socket
     |> assign(:page_title, "Bank")
     |> assign(:accounts, accounts)
     |> assign(:selected_account, nil)
     |> assign(:transaction_count, 0)
     |> stream(:transactions, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, select_account(socket, params["account_id"])}
  end

  defp select_account(socket, account_id) do
    account = find_account(socket.assigns.accounts, account_id)

    case account do
      nil ->
        socket
        |> assign(:selected_account, nil)
        |> assign(:transaction_count, 0)
        |> stream(:transactions, [], reset: true)

      account ->
        transactions = Banking.list_transactions(account.id)

        socket
        |> assign(:selected_account, account)
        |> assign(:transaction_count, length(transactions))
        |> stream(:transactions, transactions, reset: true)
    end
  end

  defp find_account(_accounts, nil), do: nil

  defp find_account(accounts, account_id) do
    case Integer.parse(to_string(account_id)) do
      {id, _} -> Enum.find(accounts, &(&1.id == id))
      :error -> nil
    end
  end

  defp list_accounts(%{assigns: %{current_scope: %{current_org: nil}}}), do: []

  defp list_accounts(%{assigns: %{current_scope: %{current_org: org}}}),
    do: Banking.list_accounts(org.id)

  defp list_accounts(_socket), do: []

  defp account_label(account) do
    [account.bank_name, account.account_number_masked && "••#{account.account_number_masked}"]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join(" ")
    |> case do
      "" -> account.label || "Account #{account.id}"
      label -> label
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      page_title={@page_title}
      current_scope={@current_scope}
      current_path={assigns[:current_path]}
    >
      <div id="bank-page" class="mx-auto max-w-5xl space-y-6">
        <.page_header eyebrow="Bank" title="Bank">
          Statement transactions, projected from extracted bank statements. Read-only —
          matching and classification land here as the engine comes online.
        </.page_header>

        <.card :if={@accounts == []} class="space-y-2">
          <h2 class="text-base-content text-h4 font-semibold">No bank accounts yet</h2>
          <p class="text-base-content/60 text-small">
            Import a bank statement to project its transactions here.
          </p>
        </.card>

        <div :if={@accounts != []} id="bank-accounts" class="flex flex-wrap gap-2">
          <.link
            :for={account <- @accounts}
            id={"bank-account-#{account.id}"}
            patch={~p"/bank?#{[account_id: account.id]}"}
            class={[
              "rounded-field text-small inline-flex h-9 items-center border px-3 font-semibold transition",
              if(@selected_account && @selected_account.id == account.id,
                do: "bg-moon/10 border-moon text-base-content",
                else: "bg-base-100 border-base-300 hover:bg-base-200 text-base-content/75"
              )
            ]}
          >
            {account_label(account)}
          </.link>
        </div>

        <div :if={@selected_account} class="space-y-3">
          <p class="text-base-content/60 text-small">
            {@transaction_count} transactions
          </p>

          <.data_table
            id="bank-transactions"
            rows={@streams.transactions}
            empty?={@transaction_count == 0}
            min_width="min-w-[760px]"
          >
            <:col :let={txn} label="Date">{format_display_date(txn.txn_date)}</:col>
            <:col :let={txn} label="Narration">{txn.narration}</:col>
            <:col :let={txn} label="Mode / Ref">
              <div class="space-y-0.5">
                <div :if={txn.mode}>{humanize_label(txn.mode)}</div>
                <div :if={txn.ref} class="text-base-content/55 text-fine">{txn.ref}</div>
              </div>
            </:col>
            <:col :let={txn} label="Debit" align="right">
              <span :if={txn.direction == "debit"}>{Decimal.to_string(txn.amount)}</span>
            </:col>
            <:col :let={txn} label="Credit" align="right">
              <span :if={txn.direction == "credit"}>{Decimal.to_string(txn.amount)}</span>
            </:col>
            <:col :let={txn} label="Balance" align="right">
              <span :if={txn.balance}>{Decimal.to_string(txn.balance)}</span>
            </:col>
            <:empty>No transactions on this account yet.</:empty>
          </.data_table>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
