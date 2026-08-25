defmodule Nila.Banking.Parsers.Kotak do
  @moduledoc """
  Parser for Kotak Mahindra Bank / 811 native account-statement PDFs.

  Kotak shifts the table three columns left after a page break and may wrap a
  narration onto the following page before the next transaction. Rows are
  normalized to the first-page geometry before amount-column classification.
  """

  @row ~r/^\s*(?<ordinal>\d+)\s+(?<date>\d{2} [A-Z][a-z]{2} \d{4})\s+(?<rest>.+)$/
  @amount ~r/-?[\d,]+\.\d{2}/

  @spec parse(binary()) :: {:ok, map()} | {:error, term()}
  def parse(text) when is_binary(text) do
    with :ok <- kotak_statement?(text),
         opening when is_integer(opening) <- opening_balance(text),
         [_first | _rest] = transactions <- parse_transactions(text),
         :ok <- reconcile(transactions, opening) do
      first = hd(transactions)
      last = List.last(transactions)

      {:ok,
       %{
         bank_code: "kotak",
         account_number_masked: masked_account(text),
         statement_from: first["date"],
         statement_to: last["date"],
         opening_balance_paise: opening,
         closing_balance_paise: last["balance_paise"],
         total_withdrawal_paise: Enum.sum(Enum.map(transactions, & &1["withdrawal_paise"])),
         total_deposit_paise: Enum.sum(Enum.map(transactions, & &1["deposit_paise"])),
         transactions: transactions,
         meta: %{
           "bank" => "Kotak Mahindra Bank",
           "parser" => "kotak_text_v1",
           "balance_reconciled" => true
         }
       }}
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
    |> Enum.map(fn transaction ->
      transaction
      |> Map.update!("narration", &normalize_narration/1)
      |> Map.put("id", transaction_id(transaction))
    end)
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

    amount = normalized |> String.slice(amount_start, amount_length) |> parse_amount!()
    balance = normalized |> String.slice(balance_start, balance_length) |> parse_amount!()
    {withdrawal, deposit} = if amount_start < 110, do: {amount, 0}, else: {0, amount}

    date = parse_date!(fields["date"])
    prefix_start = date_offset + padding + String.length(fields["date"])
    prefix_length = amount_start - prefix_start
    prefix = normalized |> String.slice(prefix_start, prefix_length) |> String.trim()
    {narration, reference} = narration_and_reference(prefix)

    %{
      "ordinal" => String.to_integer(fields["ordinal"]),
      "date" => date,
      "value_date" => date,
      "narration" => narration,
      "reference" => reference,
      "withdrawal_paise" => withdrawal,
      "deposit_paise" => deposit,
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

  defp reconcile(transactions, opening) do
    Enum.reduce_while(transactions, opening, fn transaction, previous_balance ->
      expected = previous_balance - transaction["withdrawal_paise"] + transaction["deposit_paise"]

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
      [amount] -> parse_amount!(amount)
      _missing -> nil
    end
  end

  defp masked_account(text) do
    case Regex.run(~r/Account No\.\s*(\d+)/, text, capture: :all_but_first) do
      [number] -> "•••• " <> String.slice(number, -4, 4)
      _missing -> nil
    end
  end

  defp parse_date!(value) do
    [day, month, year] = String.split(value)
    Date.new!(String.to_integer(year), month_number(month), String.to_integer(day))
  end

  defp month_number(month) do
    Enum.find_index(~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec), &(&1 == month)) + 1
  end

  defp parse_amount!(value) do
    negative? = String.starts_with?(value, "-")
    paise = value |> String.replace(~r/[^0-9]/, "") |> String.to_integer()
    if negative?, do: -paise, else: paise
  end

  defp normalize_narration(value),
    do: value |> String.replace(~r/\s+/, " ") |> String.trim()

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
end
