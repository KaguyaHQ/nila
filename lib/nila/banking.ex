defmodule Nila.Banking do
  @moduledoc """
  Bank statement spine: accounts and the structured transactions projected from
  statement extractions. Source-agnostic by design — PDF-extracted rows land
  here today, AA-pulled rows will land here unchanged later.
  """

  import Ecto.Query

  alias Nila.Banking.{Account, Transaction}
  alias Nila.Repo

  def list_accounts(org_id) do
    Repo.all(
      from account in Account,
        where: account.org_id == ^org_id,
        order_by: [asc: account.bank_name, asc: account.account_number_masked],
        preload: [:entity]
    )
  end

  def get_account(org_id, id) do
    Repo.fetch_one(
      from account in Account, where: account.org_id == ^org_id and account.id == ^id
    )
  end

  def list_transactions(bank_account_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 500)

    Repo.all(
      from transaction in Transaction,
        where: transaction.bank_account_id == ^bank_account_id,
        order_by: [desc: transaction.txn_date, desc: transaction.id],
        limit: ^limit
    )
  end

  def count_transactions(bank_account_id) do
    Repo.aggregate(
      from(transaction in Transaction, where: transaction.bank_account_id == ^bank_account_id),
      :count
    )
  end

  @doc """
  Idempotently upserts the account a statement belongs to, keyed on
  `[org_id, entity_id, account_number_masked, ifsc]` (same pattern as
  `Integrations.upsert_connection/1`).
  """
  def upsert_account(attrs) do
    %Account{}
    |> Account.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:bank_name, :label, :updated_at]},
      conflict_target: [:org_id, :entity_id, :account_number_masked, :ifsc],
      returning: true
    )
  end

  @doc """
  Projects normalized statement lines into `bank_transaction` rows under
  `account`. Each line gets a deterministic `txn_id`; re-running on an
  overlapping statement upserts on `[:bank_account_id, :txn_id]` and never
  duplicates rows. Returns `{:ok, count}`.
  """
  def upsert_transactions(%Account{} = account, lines) when is_list(lines) do
    Repo.transact(fn ->
      count =
        Enum.reduce(lines, 0, fn line, acc ->
          attrs = normalize_line(account, line)

          %Transaction{}
          |> Transaction.changeset(attrs)
          |> Repo.insert!(
            on_conflict:
              {:replace,
               [
                 :txn_date,
                 :value_date,
                 :amount,
                 :direction,
                 :balance,
                 :narration,
                 :ref,
                 :mode,
                 :raw,
                 :updated_at
               ]},
            conflict_target: [:bank_account_id, :txn_id]
          )

          acc + 1
        end)

      {:ok, count}
    end)
  end

  @doc """
  Ties a transaction to the client who paid. `client_id` is programmatic (never
  cast from extraction), so it's set explicitly on the struct.
  """
  def match_transaction(%Transaction{} = transaction, client_id) do
    transaction
    |> Ecto.Changeset.change(client_id: client_id)
    |> Repo.update()
  end

  defp normalize_line(account, line) do
    value_date = parse_date(line["value_date"]) || parse_date(line["txn_date"])
    amount = parse_decimal(line["amount"])
    direction = normalize_direction(line["direction"])
    narration = normalize_narration(line["narration"])
    ref = blank_to_nil(line["ref"])

    %{
      org_id: account.org_id,
      bank_account_id: account.id,
      txn_date: parse_date(line["txn_date"]) || value_date,
      value_date: value_date,
      amount: amount,
      direction: direction,
      balance: parse_decimal(line["balance"]),
      narration: narration,
      ref: ref,
      mode: normalize_mode(line["mode"]),
      txn_id: txn_id(account.id, value_date, amount, direction, narration, ref),
      raw: line
    }
  end

  defp txn_id(bank_account_id, value_date, amount, direction, narration, ref) do
    [
      Integer.to_string(bank_account_id),
      date_key(value_date),
      decimal_key(amount),
      to_string(direction),
      to_string(narration),
      to_string(ref)
    ]
    |> Enum.join("|")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp date_key(nil), do: ""
  defp date_key(%Date{} = date), do: Date.to_iso8601(date)

  defp decimal_key(nil), do: ""
  defp decimal_key(%Decimal{} = amount), do: Decimal.to_string(Decimal.normalize(amount))

  defp parse_date(nil), do: nil
  defp parse_date(%Date{} = date), do: date

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _} -> parse_dmy(value)
    end
  end

  defp parse_dmy(value) do
    with [d, m, y] <- String.split(value, ~r/[\/\-.]/, trim: true),
         {day, ""} <- Integer.parse(d),
         {month, ""} <- Integer.parse(m),
         {year, ""} <- Integer.parse(y),
         {:ok, date} <- Date.new(full_year(year), month, day) do
      date
    else
      _ -> nil
    end
  end

  defp full_year(year) when year < 100, do: 2000 + year
  defp full_year(year), do: year

  defp parse_decimal(nil), do: nil
  defp parse_decimal(%Decimal{} = decimal), do: decimal
  defp parse_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp parse_decimal(value) when is_float(value), do: Decimal.from_float(value)

  defp parse_decimal(value) when is_binary(value) do
    case value |> String.replace(~r/[^0-9.\-]/, "") |> Decimal.parse() do
      {decimal, _rest} -> Decimal.abs(decimal)
      :error -> nil
    end
  end

  defp normalize_direction(direction) when is_binary(direction) do
    case String.downcase(String.trim(direction)) do
      "credit" -> "credit"
      "cr" -> "credit"
      "debit" -> "debit"
      "dr" -> "debit"
      other -> other
    end
  end

  defp normalize_direction(direction), do: direction

  defp normalize_mode(nil), do: "other"

  defp normalize_mode(mode) when is_binary(mode) do
    normalized = String.downcase(String.trim(mode))
    if normalized in Transaction.modes(), do: normalized, else: "other"
  end

  defp normalize_narration(nil), do: nil

  defp normalize_narration(narration) when is_binary(narration) do
    narration |> String.replace(~r/\s+/, " ") |> String.trim()
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value),
    do: value |> String.trim() |> then(&if(&1 == "", do: nil, else: &1))

  def broadcast_progress(org_id, message) do
    Phoenix.PubSub.broadcast(Nila.PubSub, "bank_extraction:#{org_id}", message)
  end

  def subscribe(org_id) do
    Phoenix.PubSub.subscribe(Nila.PubSub, "bank_extraction:#{org_id}")
  end
end
