defmodule Nila.Banking.Parsers.Hdfc do
  @moduledoc """
  Parser for HDFC's bank-generated statement text layout.

  Transaction rows have fixed right-hand amount columns; wrapped narration
  lines occupy only the narration column. The parser preserves signed reversal
  amounts and proves every row against the printed running balance.
  """

  @row ~r/^\s*(?<date>\d{2}\/\d{2}\/\d{2})\s+(?<middle>.*?)\s+(?<value_date>\d{2}\/\d{2}\/\d{2})\s+(?<withdrawal>-?[\d,]+\.\d{2})\s+(?<deposit>-?[\d,]+\.\d{2})\s+(?<balance>-?[\d,]+\.\d{2})\s*$/
  @middle ~r/^(?<narration>.*\S)\s{2,}(?<reference>\S+)\s*$/

  @spec parse(binary()) :: {:ok, map()} | {:error, term()}
  def parse(text) when is_binary(text) do
    with :ok <- hdfc_statement?(text),
         [_first | _rest] = transactions <- parse_transactions(text),
         :ok <- reconcile(transactions) do
      first = hd(transactions)
      last = List.last(transactions)
      opening = first["balance_paise"] - first["deposit_paise"] + first["withdrawal_paise"]

      {:ok,
       %{
         bank_code: "hdfc",
         account_number_masked: masked_account(text),
         statement_from: first["date"],
         statement_to: last["date"],
         opening_balance_paise: opening,
         closing_balance_paise: last["balance_paise"],
         total_withdrawal_paise: Enum.sum(Enum.map(transactions, & &1["withdrawal_paise"])),
         total_deposit_paise: Enum.sum(Enum.map(transactions, & &1["deposit_paise"])),
         transactions: transactions,
         meta: %{
           "bank" => "HDFC Bank",
           "parser" => "hdfc_text_v1",
           "balance_reconciled" => true
         }
       }}
    else
      [] -> {:error, :unsupported_statement}
      error -> error
    end
  end

  defp parse_transactions(text) do
    text
    |> String.split("\n")
    |> Enum.reduce([], &consume_line/2)
    |> Enum.reverse()
    |> Enum.with_index(1)
    |> Enum.map(fn {transaction, ordinal} ->
      transaction
      |> Map.update!("narration", &normalize_narration/1)
      |> Map.put("ordinal", ordinal)
      |> Map.put("id", transaction_id(transaction, ordinal))
    end)
  end

  defp consume_line(line, transactions) do
    case Regex.named_captures(@row, line) do
      nil -> append_narration(transactions, continuation(line))
      fields -> [transaction(fields) | transactions]
    end
  end

  defp transaction(fields) do
    middle = Regex.named_captures(@middle, fields["middle"]) || %{}

    %{
      "date" => parse_date!(fields["date"]),
      "value_date" => parse_date!(fields["value_date"]),
      "narration" => Map.get(middle, "narration", String.trim(fields["middle"])),
      "reference" => Map.get(middle, "reference"),
      "withdrawal_paise" => parse_amount!(fields["withdrawal"]),
      "deposit_paise" => parse_amount!(fields["deposit"]),
      "balance_paise" => parse_amount!(fields["balance"])
    }
  end

  # Wrapped HDFC narration begins in column 15 and leaves the reference/value
  # and amount columns empty. That shape excludes repeated page chrome without
  # maintaining a brittle dictionary of every footer and address line.
  defp continuation(line) do
    prefix = String.slice(line, 0, 14)
    narration = String.slice(line, 14, 80)
    tail = String.slice(line, 94, max(String.length(line) - 94, 0))

    if String.trim(prefix) == "" and String.trim(narration) != "" and String.trim(tail) == "" do
      String.trim(narration)
    end
  end

  defp append_narration([transaction | rest], continuation) when is_binary(continuation) do
    [Map.update!(transaction, "narration", &(&1 <> " " <> continuation)) | rest]
  end

  defp append_narration(transactions, _continuation), do: transactions

  defp reconcile([first | rest]) do
    opening = first["balance_paise"] - first["deposit_paise"] + first["withdrawal_paise"]

    Enum.reduce_while([first | rest], opening, fn transaction, previous_balance ->
      expected =
        previous_balance - transaction["withdrawal_paise"] + transaction["deposit_paise"]

      if expected == transaction["balance_paise"],
        do: {:cont, transaction["balance_paise"]},
        else:
          {:halt,
           {:error,
            {:statement_does_not_tally, transaction["ordinal"], expected,
             transaction["balance_paise"]}}}
    end)
    |> case do
      {:error, _detail} = error -> error
      _closing_balance -> :ok
    end
  end

  defp hdfc_statement?(text) do
    if String.contains?(text, "HDFC BANK LIMITED") and
         String.contains?(text, "Withdrawal Amt.") and
         String.contains?(text, "Closing Balance") do
      :ok
    else
      {:error, :unsupported_statement}
    end
  end

  defp masked_account(text) do
    case Regex.run(~r/Account No\s*:\s*(\d+)/, text, capture: :all_but_first) do
      [number] -> "•••• " <> String.slice(number, -4, 4)
      _missing -> nil
    end
  end

  defp parse_date!(value) do
    [day, month, year] = value |> String.split("/") |> Enum.map(&String.to_integer/1)
    Date.new!(2000 + year, month, day)
  end

  defp parse_amount!(value) do
    negative? = String.starts_with?(value, "-")
    digits = String.replace(value, ~r/[^0-9]/, "")
    paise = String.to_integer(digits)
    if negative?, do: -paise, else: paise
  end

  defp normalize_narration(value),
    do: value |> String.replace(~r/\s+/, " ") |> String.trim()

  defp transaction_id(transaction, ordinal) do
    identity =
      Enum.join(
        [
          transaction["date"],
          transaction["reference"],
          transaction["withdrawal_paise"],
          transaction["deposit_paise"],
          transaction["balance_paise"],
          ordinal
        ],
        "|"
      )

    Base.encode16(:crypto.hash(:sha256, identity), case: :lower)
  end
end
