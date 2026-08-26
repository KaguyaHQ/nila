defmodule Nila.Banking.Parsers.Iob do
  @moduledoc """
  Parser for Indian Overseas Bank's native account-statement PDF layout.

  IOB prints transactions newest-first and puts the debit/credit amounts on a
  separate line for wrapped remarks. Transactions are reversed into ledger
  order before their printed running balances are reconciled.
  """

  @behaviour Nila.Banking.Parser

  alias Nila.Banking.Parser

  @row ~r/^\s*(?<date>\d{2}\/\d{2}\/\d{4})\s+(?<value_date>\d{2}\/\d{2}\/\d{4})(?<rest>.*)$/
  @amount ~r/[\d,]+\.\d{2}/

  @impl true
  def text_mode, do: :layout

  @impl true
  @spec parse(binary()) :: {:ok, map()} | {:error, term()}
  def parse(text) when is_binary(text) do
    with :ok <- iob_statement?(text),
         [_first | _rest] = transactions <- parse_transactions(text) do
      oldest = List.last(transactions)
      newest = hd(transactions)

      {statement_from, statement_to} =
        statement_period(text, oldest["date"], newest["date"])

      Parser.finalize(
        %{
          bank_code: "iob",
          account_number_masked: masked_account(text),
          statement_from: statement_from,
          statement_to: statement_to,
          meta: %{
            "bank" => "Indian Overseas Bank",
            "parser" => "iob_text_v1",
            "balance_reconciled" => true
          }
        },
        transactions,
        order: :newest_first
      )
    else
      [] -> {:error, :unsupported_statement}
      error -> error
    end
  end

  defp parse_transactions(text) do
    {transactions, current} =
      text
      |> String.split("\n")
      |> Enum.reduce({[], nil}, &consume_line/2)

    transactions
    |> finish(current)
    |> Enum.reverse()
    |> Enum.map(&transaction/1)
    |> Enum.reject(&is_nil/1)
  end

  defp consume_line(line, {transactions, current}) do
    case Regex.named_captures(@row, line) do
      nil when is_map(current) -> {transactions, Map.update!(current, :lines, &(&1 ++ [line]))}
      nil -> {transactions, current}
      fields -> {finish(transactions, current), %{fields: fields, lines: [fields["rest"]]}}
    end
  end

  defp finish(transactions, nil), do: transactions
  defp finish(transactions, current), do: [current | transactions]

  defp transaction(%{fields: fields, lines: lines}) do
    with {:ok, withdrawal, deposit, balance} <- amounts(lines) do
      {reference, narration} = narration(lines)

      %{
        "date" => Parser.numeric_date!(fields["date"], "/"),
        "value_date" => Parser.numeric_date!(fields["value_date"], "/"),
        "narration" => narration,
        "reference" => reference,
        "withdrawal_paise" => withdrawal,
        "deposit_paise" => deposit,
        "balance_paise" => balance
      }
    else
      :error -> nil
    end
  end

  defp amounts(lines) do
    Enum.find_value(lines, :error, fn line ->
      with trf when trf >= 0 <- index(line, "TRF"),
           tail <- String.slice(line, trf + 3, String.length(line)),
           [[{amount_start, amount_length}], [{balance_start, balance_length}]] <-
             Regex.scan(@amount, tail, return: :index) do
        amount = tail |> String.slice(amount_start, amount_length) |> Parser.amount_paise!()
        balance = tail |> String.slice(balance_start, balance_length) |> Parser.amount_paise!()

        if balance_start - amount_start <= 20,
          do: {:ok, 0, amount, balance},
          else: {:ok, amount, 0, balance}
      else
        _no_amounts -> nil
      end
    end)
  end

  defp index(value, match) do
    case :binary.match(value, match) do
      {offset, _length} -> offset
      :nomatch -> -1
    end
  end

  defp narration(lines) do
    parts =
      lines
      |> Enum.map(&before_amounts/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or ignored_line?(&1)))

    {reference, parts} = cheque_reference(parts)
    {reference, parts |> Enum.join(" ") |> Parser.normalize_narration()}
  end

  defp before_amounts(line) do
    case :binary.match(line, "TRF") do
      {offset, _length} -> String.slice(line, 0, offset)
      :nomatch -> line
    end
  end

  defp ignored_line?(line) do
    String.starts_with?(line, "Date and Time:") or
      String.contains?(line, "PM IST") or
      Regex.match?(~r/^Page \d+ of \d+$/, line) or
      Regex.match?(~r/^(?:[\d,]+\.\d{2}\s*)+$/, line) or
      String.starts_with?(line, "Balance in Liqui Deposit") or
      String.starts_with?(line, "Total:") or
      String.starts_with?(line, "Disclaimer")
  end

  defp cheque_reference([first | rest] = parts) do
    case Regex.run(~r/^(\d{5,8})\s+(.*)$/, first, capture: :all_but_first) do
      [reference, narration] -> {reference, [narration | rest]}
      _no_cheque -> {nil, parts}
    end
  end

  defp cheque_reference([]), do: {nil, []}

  defp iob_statement?(text) do
    if Regex.match?(~r/IFSC Code\s*:\s*IOBA\d{7}/, text) and
         String.contains?(text, "Statement for the period") and
         String.contains?(text, "Debit") and String.contains?(text, "Credit") and
         String.contains?(text, "Balance") do
      :ok
    else
      {:error, :unsupported_statement}
    end
  end

  defp masked_account(text) do
    case Regex.run(~r/Account Number\s*:\s*(\d+)/, text, capture: :all_but_first) do
      [number] -> Parser.mask_account(number)
      _missing -> nil
    end
  end

  defp statement_period(text, fallback_from, fallback_to) do
    case Regex.run(
           ~r/Statement for the period from (\d{2}-\d{2}-\d{4}).*? to (\d{2}-\d{2}-\d{4})/,
           text,
           capture: :all_but_first
         ) do
      [from, to] -> {Parser.numeric_date!(from, "-"), Parser.numeric_date!(to, "-")}
      _missing -> {fallback_from, fallback_to}
    end
  end
end
