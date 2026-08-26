defmodule Nila.Banking.Parsers.Kotak do
  @moduledoc """
  Parser for Kotak Mahindra Bank / 811 native account-statement PDFs.

  Kotak shifts the table three columns left after a page break and may wrap a
  narration onto the following page before the next transaction. Rows are
  normalized to the first-page geometry before their values are read.
  """

  @behaviour Nila.Banking.Parser

  alias Nila.Banking.Parser

  @row ~r/^\s*(?<ordinal>\d+)\s+(?<date>\d{2} [A-Z][a-z]{2} \d{4})\s+(?<rest>.+)$/
  @amount ~r/-?[\d,]+\.\d{2}/

  @impl true
  def text_mode, do: :layout

  @impl true
  @spec parse(binary()) :: {:ok, map()} | {:error, term()}
  def parse(text) when is_binary(text) do
    with :ok <- kotak_statement?(text),
         opening when is_integer(opening) <- opening_balance(text),
         [_first | _rest] = transactions <- parse_transactions(text) do
      first = hd(transactions)
      last = List.last(transactions)

      Parser.finalize(
        %{
          bank_code: "kotak",
          account_number_masked: masked_account(text),
          statement_from: first["date"],
          statement_to: last["date"],
          opening_balance_paise: opening,
          meta: %{
            "bank" => "Kotak Mahindra Bank",
            "parser" => "kotak_text_v1",
            "balance_reconciled" => true
          }
        },
        transactions
      )
    else
      nil -> {:error, :unsupported_statement}
      [] -> {:error, :unsupported_statement}
      error -> error
    end
  end

  defp parse_transactions(text) do
    text
    |> String.split("Account Summary", parts: 2)
    |> hd()
    |> String.split("\n")
    |> Enum.reduce([], &consume_line/2)
    |> Enum.reverse()
    |> Enum.map(&Map.update!(&1, "narration", fn value -> Parser.normalize_narration(value) end))
  end

  defp consume_line(line, transactions) do
    case Regex.named_captures(@row, line) do
      nil -> append_narration(transactions, continuation(line))
      fields -> [transaction(line, fields) | transactions]
    end
  end

  defp transaction(line, fields) do
    date_offset = line |> :binary.match(fields["date"]) |> elem(0)
    padding = max(12 - date_offset, 0)
    normalized = String.duplicate(" ", padding) <> line
    matches = Regex.scan(@amount, normalized, return: :index)

    [[{balance_start, balance_length}], [{amount_start, amount_length}] | _] =
      Enum.reverse(matches)

    amount = normalized |> String.slice(amount_start, amount_length) |> Parser.amount_paise!()
    balance = normalized |> String.slice(balance_start, balance_length) |> Parser.amount_paise!()

    date = Parser.named_date!(fields["date"], " ")
    prefix_start = date_offset + padding + String.length(fields["date"])
    prefix_length = amount_start - prefix_start
    prefix = normalized |> String.slice(prefix_start, prefix_length) |> String.trim()
    {narration, reference} = narration_and_reference(prefix)

    %{
      "date" => date,
      "value_date" => date,
      "narration" => narration,
      "reference" => reference,
      "amount_paise" => amount,
      "balance_paise" => balance
    }
  end

  defp narration_and_reference(prefix) do
    case Regex.run(~r/^(.*\S)\s+((?:UPI-[A-Z0-9-]+|\d{8,}))$/, prefix, capture: :all_but_first) do
      [narration, reference] -> {String.trim(narration), reference}
      _no_reference -> {prefix, nil}
    end
  end

  defp continuation(line) do
    spaces = byte_size(line) - byte_size(String.trim_leading(line))
    content = String.trim(line)

    if spaces in [23, 26] and content != "" and not ignored_continuation?(content),
      do: content
  end

  defp ignored_continuation?(content) do
    String.contains?(content, "Savings Account Transactions") or
      String.starts_with?(content, "Statement Generated")
  end

  defp append_narration([transaction | rest], continuation) when is_binary(continuation) do
    [Map.update!(transaction, "narration", &(&1 <> " " <> continuation)) | rest]
  end

  defp append_narration(transactions, _continuation), do: transactions

  defp kotak_statement?(text) do
    if String.contains?(text, "Kotak Mahindra Bank") and
         String.contains?(text, "Withdrawal (Dr.)") and
         String.contains?(text, "Deposit (Cr.)") do
      :ok
    else
      {:error, :unsupported_statement}
    end
  end

  defp opening_balance(text) do
    case Regex.run(~r/Opening Balance.*?(-?[\d,]+\.\d{2})\s*$/m, text, capture: :all_but_first) do
      [amount] -> Parser.amount_paise!(amount)
      _missing -> nil
    end
  end

  defp masked_account(text) do
    case Regex.run(~r/Account No\.\s*(\d+)/, text, capture: :all_but_first) do
      [number] -> Parser.mask_account(number)
      _missing -> nil
    end
  end
end
