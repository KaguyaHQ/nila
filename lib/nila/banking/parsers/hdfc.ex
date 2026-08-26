defmodule Nila.Banking.Parsers.Hdfc do
  @moduledoc """
  Parser for HDFC's bank-generated statement text layout.

  Transaction rows have fixed right-hand amount columns; wrapped narration
  lines occupy only the narration column. The parser preserves signed reversal
  amounts and proves every row against the printed running balance.
  """

  @behaviour Nila.Banking.Parser

  alias Nila.Banking.Parser

  @row ~r/^\s*(?<date>\d{2}\/\d{2}\/\d{2})\s+(?<middle>.*?)\s+(?<value_date>\d{2}\/\d{2}\/\d{2})\s+(?<withdrawal>-?[\d,]+\.\d{2})\s+(?<deposit>-?[\d,]+\.\d{2})\s+(?<balance>-?[\d,]+\.\d{2})\s*$/
  @middle ~r/^(?<narration>.*\S)\s{2,}(?<reference>\S+)\s*$/

  @impl true
  def text_mode, do: :layout

  @impl true
  @spec parse(binary()) :: {:ok, map()} | {:error, term()}
  def parse(text) when is_binary(text) do
    with :ok <- hdfc_statement?(text),
         [_first | _rest] = transactions <- parse_transactions(text) do
      first = hd(transactions)
      last = List.last(transactions)

      Parser.finalize(
        %{
          bank_code: "hdfc",
          account_number_masked: masked_account(text),
          statement_from: first["date"],
          statement_to: last["date"],
          meta: %{
            "bank" => "HDFC Bank",
            "parser" => "hdfc_text_v1",
            "balance_reconciled" => true
          }
        },
        transactions
      )
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
    |> Enum.map(&Map.update!(&1, "narration", fn value -> Parser.normalize_narration(value) end))
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
      "date" => Parser.numeric_date!(fields["date"], "/", :two_digit),
      "value_date" => Parser.numeric_date!(fields["value_date"], "/", :two_digit),
      "narration" => Map.get(middle, "narration", String.trim(fields["middle"])),
      "reference" => Map.get(middle, "reference"),
      "withdrawal_paise" => Parser.amount_paise!(fields["withdrawal"]),
      "deposit_paise" => Parser.amount_paise!(fields["deposit"]),
      "balance_paise" => Parser.amount_paise!(fields["balance"])
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
      [number] -> Parser.mask_account(number)
      _missing -> nil
    end
  end
end
