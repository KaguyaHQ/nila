defmodule Nila.Banking.Parser do
  @moduledoc """
  Shared contract and accounting finalizer for deterministic bank-statement parsers.

  Layout adapters own detection and row extraction. This module owns ordering,
  debit/credit resolution, running-balance reconciliation, stable transaction
  identity, totals, and the final artifact shape.
  """

  @type text_mode :: :layout | :raw
  @type parse_result :: {:ok, map()} | {:error, term()}

  @callback text_mode() :: text_mode()
  @callback parse(binary()) :: parse_result()

  @required_metadata ~w(bank_code account_number_masked statement_from statement_to meta)a

  @spec finalize(map(), [map()], keyword()) :: parse_result()
  def finalize(metadata, rows, opts \\ []) when is_map(metadata) and is_list(rows) do
    order = Keyword.get(opts, :order, :oldest_first)
    rows = order_rows(rows, order)

    with :ok <- metadata?(metadata),
         [_first | _rest] <- rows,
         {:ok, opening} <- opening_balance(metadata, rows),
         {:ok, transactions} <- reconcile(rows, opening) do
      {:ok,
       %{
         bank_code: metadata.bank_code,
         account_number_masked: metadata.account_number_masked,
         statement_from: metadata.statement_from,
         statement_to: metadata.statement_to,
         opening_balance_paise: opening,
         closing_balance_paise: List.last(transactions)["balance_paise"],
         total_withdrawal_paise: sum(transactions, "withdrawal_paise"),
         total_deposit_paise: sum(transactions, "deposit_paise"),
         transactions: transactions,
         meta: metadata.meta
       }}
    else
      [] -> {:error, :unsupported_statement}
      error -> error
    end
  end

  @spec amount_paise!(binary()) :: integer()
  def amount_paise!(value) when is_binary(value) do
    negative? = String.starts_with?(value, "-")
    paise = value |> String.replace(~r/[^0-9]/, "") |> String.to_integer()
    if negative?, do: -paise, else: paise
  end

  @spec numeric_date!(binary(), binary(), :two_digit | :four_digit) :: Date.t()
  def numeric_date!(value, separator, year_digits \\ :four_digit) do
    [day, month, year] = value |> String.split(separator) |> Enum.map(&String.to_integer/1)
    year = if year_digits == :two_digit, do: 2000 + year, else: year
    Date.new!(year, month, day)
  end

  @spec named_date!(binary(), binary(), :two_digit | :four_digit) :: Date.t()
  def named_date!(value, separator, year_digits \\ :four_digit) do
    [day, month, year] = String.split(value, separator)
    year = String.to_integer(year)
    year = if year_digits == :two_digit, do: 2000 + year, else: year
    Date.new!(year, month_number(month), String.to_integer(day))
  end

  @spec normalize_narration(binary()) :: binary()
  def normalize_narration(value) when is_binary(value),
    do: value |> String.replace(~r/\s+/, " ") |> String.trim()

  @spec mask_account(binary() | nil) :: binary() | nil
  def mask_account(number) when is_binary(number), do: "•••• " <> String.slice(number, -4, 4)
  def mask_account(nil), do: nil

  defp metadata?(metadata) do
    if Enum.all?(@required_metadata, &Map.has_key?(metadata, &1)),
      do: :ok,
      else: {:error, :invalid_parser_metadata}
  end

  defp order_rows(rows, :oldest_first), do: rows
  defp order_rows(rows, :newest_first), do: Enum.reverse(rows)

  defp opening_balance(%{opening_balance_paise: opening}, _rows) when is_integer(opening),
    do: {:ok, opening}

  defp opening_balance(_metadata, [
         %{"signed_amount_paise" => amount, "balance_paise" => balance} | _rest
       ])
       when is_integer(amount) and is_integer(balance),
       do: {:ok, balance - amount}

  defp opening_balance(_metadata, [first | _rest]) do
    with {:ok, withdrawal, deposit} <- explicit_amounts(first) do
      {:ok, first["balance_paise"] + withdrawal - deposit}
    end
  end

  defp reconcile(rows, opening) do
    rows
    |> Enum.with_index(1)
    |> Enum.reduce_while({opening, []}, fn {row, ordinal}, {previous_balance, transactions} ->
      case resolve_amounts(row, previous_balance) do
        {:ok, withdrawal, deposit} ->
          expected = previous_balance - withdrawal + deposit

          if expected == row["balance_paise"] do
            transaction =
              row
              |> Map.delete("amount_paise")
              |> Map.delete("signed_amount_paise")
              |> Map.put("withdrawal_paise", withdrawal)
              |> Map.put("deposit_paise", deposit)
              |> Map.put("ordinal", ordinal)
              |> then(&Map.put(&1, "id", transaction_id(&1)))

            {:cont, {row["balance_paise"], [transaction | transactions]}}
          else
            {:halt,
             {:error, {:statement_does_not_tally, ordinal, expected, row["balance_paise"]}}}
          end

        {:error, expected} ->
          {:halt, {:error, {:statement_does_not_tally, ordinal, expected, row["balance_paise"]}}}
      end
    end)
    |> case do
      {:error, _detail} = error -> error
      {_closing_balance, transactions} -> {:ok, Enum.reverse(transactions)}
    end
  end

  defp resolve_amounts(%{"amount_paise" => amount, "balance_paise" => balance}, previous)
       when is_integer(amount) do
    cond do
      previous - amount == balance -> {:ok, amount, 0}
      previous + amount == balance -> {:ok, 0, amount}
      true -> {:error, previous - amount}
    end
  end

  defp resolve_amounts(%{"signed_amount_paise" => amount}, _previous)
       when is_integer(amount) do
    if amount < 0,
      do: {:ok, abs(amount), 0},
      else: {:ok, 0, amount}
  end

  defp resolve_amounts(row, _previous), do: explicit_amounts(row)

  defp explicit_amounts(%{"withdrawal_paise" => withdrawal, "deposit_paise" => deposit})
       when is_integer(withdrawal) and is_integer(deposit),
       do: {:ok, withdrawal, deposit}

  defp explicit_amounts(_row), do: {:error, :invalid_transaction_amounts}

  defp sum(transactions, field), do: Enum.sum(Enum.map(transactions, & &1[field]))

  defp transaction_id(transaction) do
    identity =
      Enum.join(
        [
          transaction["date"],
          transaction["reference"],
          transaction["withdrawal_paise"],
          transaction["deposit_paise"],
          transaction["balance_paise"],
          transaction["ordinal"]
        ],
        "|"
      )

    Base.encode16(:crypto.hash(:sha256, identity), case: :lower)
  end

  defp month_number(month) do
    Enum.find_index(~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec), &(&1 == month)) + 1
  end
end
