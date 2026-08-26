defmodule Nila.Banking.Parsers.KotakLegacy do
  @moduledoc """
  Parser for Kotak's older personal-account statement layout.

  These statements have no row ordinal, print balances with a `(Cr)` / `(Dr)`
  suffix, and include the opening balance as the first table row.
  """

  @behaviour Nila.Banking.Parser

  alias Nila.Banking.Parser

  @row ~r/^\s*(?<date>\d{2}-[A-Z][a-z]{2}-\d{2})\s+(?<rest>.+)$/
  @amount ~r/[\d,]+\.\d{2}/

  @impl true
  def text_mode, do: :layout

  @impl true
  @spec parse(binary()) :: {:ok, map()} | {:error, term()}
  def parse(text) when is_binary(text) do
    with :ok <- kotak_statement?(text),
         {opening, [_first | _rest] = transactions} <- parse_transactions(text),
         true <- is_integer(opening) do
      first = hd(transactions)
      last = List.last(transactions)
      {statement_from, statement_to} = statement_period(text, first["date"], last["date"])

      Parser.finalize(
        %{
          bank_code: "kotak",
          account_number_masked: masked_account(text),
          statement_from: statement_from,
          statement_to: statement_to,
          opening_balance_paise: opening,
          meta: %{
            "bank" => "Kotak Mahindra Bank",
            "parser" => "kotak_legacy_text_v1",
            "balance_reconciled" => true
          }
        },
        transactions
      )
    else
      {nil, _transactions} -> {:error, :unsupported_statement}
      {_opening, []} -> {:error, :unsupported_statement}
      false -> {:error, :unsupported_statement}
      error -> error
    end
  end

  defp parse_transactions(text) do
    {rows, current} =
      text
      |> String.split("\n")
      |> Enum.reduce({[], nil}, &consume_line/2)

    parsed = rows |> finish(current) |> Enum.reverse() |> Enum.map(&transaction/1)
    opening = Enum.find_value(parsed, fn {kind, value} -> kind == :opening && value end)

    transactions =
      parsed
      |> Enum.filter(fn {kind, _value} -> kind == :transaction end)
      |> Enum.map(&elem(&1, 1))

    {opening, transactions}
  end

  defp consume_line(line, {rows, current}) do
    if String.contains?(line, "Statement Summary") do
      {finish(rows, current), nil}
    else
      case Regex.named_captures(@row, line) do
        nil when is_map(current) -> {rows, Map.update!(current, :lines, &(&1 ++ [line]))}
        nil -> {rows, current}
        fields -> {finish(rows, current), %{fields: fields, lines: [fields["rest"]]}}
      end
    end
  end

  defp finish(rows, nil), do: rows
  defp finish(rows, current), do: [current | rows]

  defp transaction(%{fields: fields, lines: lines}) do
    line = hd(lines)
    amounts = Regex.scan(@amount, line, return: :index)

    if String.contains?(line, "OPENING BALANCE") do
      {:opening, balance(line, amounts)}
    else
      {:transaction, build_transaction(fields, lines, line, amounts)}
    end
  end

  defp build_transaction(fields, lines, line, amounts) do
    [[{amount_start, amount_length}], [{_balance_start, _balance_length}]] = amounts
    amount = line |> String.slice(amount_start, amount_length) |> Parser.amount_paise!()
    balance = balance(line, amounts)

    prefix = line |> String.slice(0, amount_start) |> String.trim()
    {narration, reference} = narration_and_reference(prefix)
    continuation = lines |> tl() |> Enum.reject(&ignored_line?/1) |> Enum.map(&String.trim/1)

    transaction = %{
      "date" => Parser.named_date!(fields["date"], "-", :two_digit),
      "value_date" => Parser.named_date!(fields["date"], "-", :two_digit),
      "narration" => Parser.normalize_narration(Enum.join([narration | continuation], " ")),
      "reference" => reference,
      "amount_paise" => amount,
      "balance_paise" => balance
    }

    transaction
  end

  defp balance(line, amounts) do
    [{start, length}] = List.last(amounts)
    amount = line |> String.slice(start, length) |> Parser.amount_paise!()
    suffix = String.slice(line, start + length, String.length(line))
    if String.contains?(suffix, "(Dr)"), do: -amount, else: amount
  end

  defp narration_and_reference(prefix) do
    case Regex.run(~r/^(.*\S)\s{2,}(\S+)$/, prefix, capture: :all_but_first) do
      [narration, reference] -> {String.trim(narration), reference}
      _no_reference -> {prefix, nil}
    end
  end

  defp ignored_line?(line) do
    value = String.trim(line)

    value == "" or value == "Contd." or
      String.starts_with?(value, "AP-Autopay") or
      String.starts_with?(value, "Management Service") or
      String.starts_with?(value, "Shopping transaction") or
      String.starts_with?(value, "UPI-Unified") or
      (String.contains?(value, "Period") and String.contains?(value, "Currency")) or
      (String.starts_with?(value, "Date") and String.contains?(value, "Narration"))
  end

  defp kotak_statement?(text) do
    if Regex.match?(~r/IFSC Code\s+KKBK\d{7}/, text) and
         String.contains?(text, "Statement of Banking Account") and
         String.contains?(text, "Withdrawal (Dr)") and
         String.contains?(text, "Deposit (Cr)") do
      :ok
    else
      {:error, :unsupported_statement}
    end
  end

  defp masked_account(text) do
    case Regex.run(~r/Account No\.\s+(\d+)/, text, capture: :all_but_first) do
      [number] -> Parser.mask_account(number)
      _missing -> nil
    end
  end

  defp statement_period(text, fallback_from, fallback_to) do
    case Regex.run(~r/Period\s+(\d{2}-[A-Z][a-z]{2}-\d{2}) to (\d{2}-[A-Z][a-z]{2}-\d{2})/, text,
           capture: :all_but_first
         ) do
      [from, to] ->
        {Parser.named_date!(from, "-", :two_digit), Parser.named_date!(to, "-", :two_digit)}

      _missing ->
        {fallback_from, fallback_to}
    end
  end
end
