defmodule Nila.Banking.Parsers.Kotak do
  @moduledoc """
  Parser for Kotak Mahindra Bank / 811 native account-statement PDFs.

  Kotak has classic separate amount columns and newer exports with either a
  signed amount column or signed debit/credit columns. All variants feed the
  same row and running-balance normalizer.
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
         layout when is_map(layout) <- layout(text),
         [_first | _rest] = transactions <- parse_transactions(text, layout) do
      order = transaction_order(transactions)

      chronological =
        if order == :newest_first, do: Enum.reverse(transactions), else: transactions

      first = hd(chronological)
      last = List.last(chronological)
      {statement_from, statement_to} = statement_period(text, first["date"], last["date"])

      metadata =
        %{
          bank_code: "kotak",
          account_number_masked: masked_account(text),
          statement_from: statement_from,
          statement_to: statement_to,
          meta: %{
            "bank" => "Kotak Mahindra Bank",
            "parser" => layout.parser,
            "balance_reconciled" => true
          }
        }
        |> maybe_put_opening_balance(opening_balance(text))

      Parser.finalize(
        metadata,
        transactions,
        order: order
      )
    else
      nil -> {:error, :unsupported_statement}
      [] -> {:error, :unsupported_statement}
      error -> error
    end
  end

  defp parse_transactions(text, layout) do
    text
    |> String.split("Account Summary", parts: 2)
    |> hd()
    |> String.split("\n")
    |> Enum.reduce([], &consume_line(&1, &2, layout))
    |> Enum.reverse()
    |> Enum.map(&Map.update!(&1, "narration", fn value -> Parser.normalize_narration(value) end))
  end

  defp consume_line(line, transactions, layout) do
    case Regex.named_captures(@row, line) do
      nil -> append_narration(transactions, continuation(line, layout))
      fields -> [transaction(line, fields, layout) | transactions]
    end
  end

  defp transaction(line, fields, %{family: :classic}) do
    date_offset = line |> :binary.match(fields["date"]) |> elem(0)
    padding = max(12 - date_offset, 0)
    normalized = String.duplicate(" ", padding) <> line
    matches = Regex.scan(@amount, normalized, return: :index)

    [[{balance_start, balance_length}], [{amount_start, amount_length}] | _] =
      Enum.reverse(matches)

    amount =
      normalized |> String.slice(amount_start, amount_length) |> Parser.amount_paise!() |> abs()

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

  defp transaction(line, fields, layout) do
    date_offset = line |> :binary.match(fields["date"]) |> elem(0)
    prefix_start = date_offset + String.length(fields["date"])
    matches = Regex.scan(@amount, line, return: :index)

    [[{balance_start, balance_length}], [{amount_start, amount_length}] | _] =
      Enum.reverse(matches)

    amount = line |> String.slice(amount_start, amount_length) |> Parser.amount_paise!()
    balance = line |> String.slice(balance_start, balance_length) |> Parser.amount_paise!()

    prefix =
      line
      |> String.slice(prefix_start, amount_start - prefix_start)
      |> strip_value_date(layout)

    {narration, reference} = narration_and_reference(prefix)

    %{
      "date" => Parser.named_date!(fields["date"], " "),
      "value_date" => value_date(line, layout) || Parser.named_date!(fields["date"], " "),
      "narration" => narration,
      "reference" => blank_to_nil(reference),
      "signed_amount_paise" => amount,
      "balance_paise" => balance
    }
  end

  defp narration_and_reference(prefix) do
    case Regex.run(~r/^(.*\S)\s+((?:UPI-[A-Z0-9-]+|\d{8,}))$/, prefix, capture: :all_but_first) do
      [narration, reference] -> {String.trim(narration), reference}
      _no_reference -> {prefix, nil}
    end
  end

  defp continuation(line, %{family: :classic}) do
    spaces = byte_size(line) - byte_size(String.trim_leading(line))
    content = String.trim(line)

    if spaces in [23, 26] and content != "" and not ignored_continuation?(content),
      do: content
  end

  defp continuation(line, layout) do
    content =
      case Regex.run(~r/^\s+\d{2}:\d{2} [AP]M\s+(.*\S)\s*$/, line, capture: :all_but_first) do
        [value] -> value
        _no_time -> column(line, layout.narration_start, layout.reference_start)
      end

    if content != "" and not ignored_continuation?(content), do: content
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
    classic? =
      String.contains?(text, "Kotak Mahindra Bank") and
        String.contains?(text, "Withdrawal (Dr.)") and
        String.contains?(text, "Deposit (Cr.)")

    modern? =
      Regex.match?(~r/IFSC\s+KKBK\d{7}/, text) and
        String.contains?(text, "Account Statement") and
        String.contains?(text, "TRANSACTION DETAILS") and
        String.contains?(text, "BALANCE(")

    if classic? or modern? do
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
    case Regex.run(~r/Account (?:No\.|#)\s*(\d+)/, text, capture: :all_but_first) do
      [number] -> Parser.mask_account(number)
      _missing -> nil
    end
  end

  defp layout(text) do
    cond do
      String.contains?(text, "DEBIT/CREDIT(") ->
        modern_layout(text, :modern_combined, "kotak_text_v2_combined", "VALUE DATE", 3)

      String.contains?(text, "DEBIT(") and String.contains?(text, "CREDIT(") ->
        modern_layout(text, :modern_split, "kotak_text_v2_split", nil, 1)

      String.contains?(text, "Withdrawal (Dr.)") ->
        %{family: :classic, parser: "kotak_text_v1"}

      true ->
        nil
    end
  end

  defp modern_layout(text, family, parser, value_date_label, reference_adjustment) do
    value_date_start = value_date_label && header_column(text, value_date_label)
    narration_start = header_column(text, "TRANSACTION DETAILS")
    reference_start = header_column(text, "CHQ / REF NO.")

    if is_integer(narration_start) and is_integer(reference_start) and
         (is_nil(value_date_label) or is_integer(value_date_start)) do
      %{
        family: family,
        parser: parser,
        value_date_start: value_date_start,
        narration_start: narration_start,
        reference_start: reference_start - reference_adjustment
      }
    end
  end

  defp header_column(text, label) do
    text
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case :binary.match(line, label) do
        {offset, _length} -> offset
        :nomatch -> nil
      end
    end)
  end

  defp column(line, start, stop)
       when is_integer(start) and is_integer(stop) and stop > start do
    line |> String.slice(start, stop - start) |> String.trim()
  end

  defp column(_line, _start, _stop), do: ""

  defp value_date(_line, %{value_date_start: nil}), do: nil

  defp value_date(line, layout) do
    value = column(line, layout.value_date_start, layout.narration_start)

    case Regex.run(~r/\d{2} [A-Z][a-z]{2} \d{4}/, value) do
      [date] -> Parser.named_date!(date, " ")
      _missing -> nil
    end
  end

  defp strip_value_date(prefix, %{family: :modern_combined}) do
    prefix
    |> String.trim()
    |> String.replace(~r/^\d{2} [A-Z][a-z]{2} \d{4}\s+/, "")
  end

  defp strip_value_date(prefix, _layout), do: String.trim(prefix)

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp transaction_order([first | rest]) do
    case List.last(rest) do
      nil -> :oldest_first
      last -> if Date.after?(first["date"], last["date"]), do: :newest_first, else: :oldest_first
    end
  end

  defp maybe_put_opening_balance(metadata, opening) when is_integer(opening),
    do: Map.put(metadata, :opening_balance_paise, opening)

  defp maybe_put_opening_balance(metadata, _opening), do: metadata

  defp statement_period(text, fallback_from, fallback_to) do
    case Regex.run(
           ~r/(\d{2} [A-Z][a-z]{2} \d{4})\s*-\s*(\d{2} [A-Z][a-z]{2} \d{4})/,
           text,
           capture: :all_but_first
         ) do
      [from, to] -> {Parser.named_date!(from, " "), Parser.named_date!(to, " ")}
      _missing -> {fallback_from, fallback_to}
    end
  end
end
