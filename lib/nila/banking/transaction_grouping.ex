defmodule Nila.Banking.TransactionGrouping do
  @moduledoc """
  Builds conservative bank-transaction groups that can share one ledger decision.

  Groups require the same direction and a deterministic bank-rail fingerprint. Changing
  bank references and dates may be discarded, but accounting-relevant narration is not.
  False negatives are intentional: the same payee alone is not enough evidence for the
  same accounting ledger when the source contains conflicting payment purposes.
  """

  alias Nila.Banking.Transaction

  @upi_handle ~r/^(.*?)[-\/]([A-Z0-9._]+@[A-Z0-9 ]+)(.*)$/
  @ifsc ~r/^[A-Z]{4}0[A-Z0-9]{6}$/
  @long_number ~r/^\d{6,}$/
  @generic_patterns ~w(NA UPI PAYMENT TRANSFER UPIPAYMENT)

  @spec group([Transaction.t()]) :: %{groups: [map()], individuals: [Transaction.t()]}
  def group(transactions) when is_list(transactions) do
    {candidates, individuals} =
      Enum.reduce(transactions, {%{}, []}, fn transaction, {grouped, individual} ->
        case candidate(transaction) do
          nil ->
            {grouped, [transaction | individual]}

          candidate ->
            {Map.update(grouped, candidate.fingerprint, [candidate], &[candidate | &1]),
             individual}
        end
      end)

    {groups, singleton_transactions} =
      Enum.reduce(candidates, {[], individuals}, fn
        {_fingerprint, [_single = %{transaction: transaction}]}, {groups, individuals} ->
          {groups, [transaction | individuals]}

        {fingerprint, candidates}, {groups, individuals} ->
          candidates = Enum.sort_by(candidates, & &1.transaction.ordinal)
          transactions = Enum.map(candidates, & &1.transaction)
          first = hd(candidates)

          group = %{
            key: group_key(fingerprint),
            payee: first.payee,
            pattern: first.pattern,
            match_basis: first.match_basis,
            transaction_type: first.transaction.transaction_type,
            transactions: transactions,
            transaction_ids: MapSet.new(transactions, & &1.id),
            count: length(transactions),
            total_paise: Enum.sum(Enum.map(transactions, &transaction_amount/1)),
            first_ordinal: first.transaction.ordinal
          }

          {[group | groups], individuals}
      end)

    %{
      groups: Enum.sort_by(groups, &{-&1.count, &1.first_ordinal}),
      individuals: Enum.sort_by(singleton_transactions, & &1.ordinal)
    }
  end

  defp candidate(%Transaction{narration: narration} = transaction)
       when is_binary(narration) do
    normalized = narration |> String.upcase() |> String.replace(~r/\s+/, " ") |> String.trim()

    upi_candidate(transaction, normalized) ||
      bank_charge_candidate(transaction, normalized) ||
      bank_interest_candidate(transaction, normalized) ||
      card_merchant_candidate(transaction, normalized) ||
      pos_merchant_candidate(transaction, normalized) ||
      neft_candidate(transaction, normalized) ||
      billpay_candidate(transaction, normalized) ||
      imps_candidate(transaction, normalized) ||
      tpt_candidate(transaction, normalized)
  end

  defp candidate(_transaction), do: nil

  defp upi_candidate(transaction, normalized) do
    with true <-
           String.starts_with?(normalized, "UPI-") or String.starts_with?(normalized, "UPI/"),
         [_, prefix, handle, tail] <- Regex.run(@upi_handle, normalized),
         payee when payee != "" <- payee(prefix),
         handle when handle != "" <- compact(handle),
         pattern when pattern != "" <- stable_pattern(tail),
         false <- compact(pattern) in @generic_patterns do
      %{
        fingerprint:
          {:upi, transaction.transaction_type, compact(payee), handle, compact(pattern)},
        payee: humanize(payee),
        pattern: pattern,
        match_basis: "Same payee and payment pattern",
        transaction: transaction
      }
    else
      _ -> nil
    end
  end

  defp bank_charge_candidate(transaction, normalized) do
    if Regex.match?(~r/^\.?DC INTL POS TXN (?:MARKUP|DCC)\+ST\b/, normalized) or
         Regex.match?(~r/^\.?POS DECCHG\b/, normalized) or
         String.starts_with?(normalized, "AQB SER CHGS INC GST ") do
      group_candidate(
        transaction,
        {:bank_charge, transaction.transaction_type},
        "Bank charges",
        "Same bank charge"
      )
    end
  end

  defp bank_interest_candidate(transaction, normalized) do
    if String.starts_with?(normalized, "INTEREST PAID TILL ") do
      group_candidate(
        transaction,
        {:bank_interest, transaction.transaction_type, :interest_paid},
        "Bank interest",
        "Same bank credit"
      )
    end
  end

  defp card_merchant_candidate(transaction, normalized) do
    case Regex.run(~r/^ME DC SI (\d{4,6}[X*]{4,}\d{4}) (.+)$/, normalized) do
      [_, card, merchant] ->
        {merchant_key, merchant_name} = card_merchant_identity(merchant)

        group_candidate(
          transaction,
          {:card_merchant, transaction.transaction_type, compact(card), merchant_key},
          merchant_name,
          "Same card and merchant"
        )

      _ ->
        nil
    end
  end

  defp pos_merchant_candidate(transaction, normalized) do
    case Regex.run(~r/^POS (\d{4,6}[X*]{4,}\d{4}) (.+)$/, normalized) do
      [_, card, merchant] ->
        {merchant_key, merchant_name} = card_merchant_identity(merchant)

        group_candidate(
          transaction,
          {:card_merchant, transaction.transaction_type, compact(card), merchant_key},
          merchant_name,
          "Same card and merchant"
        )

      _ ->
        nil
    end
  end

  defp neft_candidate(transaction, normalized) do
    case String.split(normalized, "-", trim: true) do
      ["NEFT " <> direction, bank, payee | details] when direction in ["CR", "DR"] ->
        stable_details = Enum.reject(details, &bank_transfer_reference?/1)

        group_candidate(
          transaction,
          {:neft, transaction.transaction_type, direction, compact(bank), compact(payee),
           Enum.map(stable_details, &compact/1)},
          humanize(payee),
          "Same NEFT details",
          stable_details |> Enum.join(" · ") |> blank_to_nil()
        )

      _ ->
        nil
    end
  end

  defp billpay_candidate(transaction, normalized) do
    case Regex.run(~r/^IB BILLPAY (CR|DR)-([A-Z0-9]+)-([0-9X* ]+) \d+$/, normalized) do
      [_, direction, biller, account] ->
        account = compact(account)

        group_candidate(
          transaction,
          {:billpay, transaction.transaction_type, direction, biller, account},
          "Bill payment · ••••#{String.slice(account, -4, 4)}",
          "Same bill-pay account"
        )

      _ ->
        nil
    end
  end

  defp imps_candidate(transaction, normalized) do
    case Regex.run(~r/^IMPS-\d+-(.+)$/, normalized) do
      [_, details] ->
        case String.split(details, "-", trim: true) do
          [payee, _bank, _account, _memo | _rest] ->
            group_candidate(
              transaction,
              {:imps, transaction.transaction_type, compact(details)},
              humanize(payee),
              "Same beneficiary and payment details"
            )

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp tpt_candidate(transaction, normalized) do
    case Regex.run(~r/^(\d{10,})-TPT-(.+)$/, normalized) do
      [_, account, details] ->
        parts = String.split(details, "-", trim: true)

        case Enum.reverse(parts) do
          [payee | reversed_pattern] ->
            pattern = reversed_pattern |> Enum.reverse() |> Enum.join(" · ") |> blank_to_nil()

            group_candidate(
              transaction,
              {:tpt, transaction.transaction_type, account, compact(details)},
              humanize(payee),
              "Same bank transfer details",
              pattern
            )

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp group_candidate(transaction, fingerprint, payee, match_basis, pattern \\ nil) do
    %{
      fingerprint: fingerprint,
      payee: payee,
      pattern: pattern,
      match_basis: match_basis,
      transaction: transaction
    }
  end

  defp card_merchant_identity(merchant) do
    normalized =
      merchant
      |> String.split(" ", trim: true)
      |> Enum.drop_while(&card_metadata_token?/1)
      |> Enum.reverse()
      |> Enum.drop_while(&generic_card_descriptor?/1)
      |> Enum.reverse()
      |> Enum.join(" ")

    normalized = if normalized == "", do: merchant, else: normalized
    {compact(normalized), humanize(normalized)}
  end

  defp card_metadata_token?(token) do
    Regex.match?(~r/^\d{10,}$/, token) or
      Regex.match?(~r/^\d{2}[A-Z]{3}\d{2}$/, token) or
      Regex.match?(~r/^\d{2}:\d{2}:\d{2}$/, token) or
      Regex.match?(~r/^\+\d{8,}$/, token)
  end

  defp generic_card_descriptor?(token), do: Regex.match?(~r/^SUBSCR(?:IPTION)?$/, token)

  defp bank_transfer_reference?(value) do
    value |> compact() |> then(&Regex.match?(~r/^[A-Z]{1,8}\d{10,}$/, &1))
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp payee(prefix) do
    prefix
    |> String.split(~r/[-\/]/, trim: true)
    |> Enum.reject(&(&1 == "UPI"))
    |> List.last()
    |> case do
      nil -> ""
      value -> String.trim(value)
    end
  end

  defp stable_pattern(tail) do
    tail
    |> String.split(~r/[-\/]/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.drop_while(&bank_reference?/1)
    |> Enum.join(" · ")
  end

  defp bank_reference?(token) do
    token = compact(token)
    token == "" or Regex.match?(@ifsc, token) or Regex.match?(@long_number, token)
  end

  defp compact(value), do: String.replace(value, ~r/[^A-Z0-9@._]/, "")

  defp humanize(value) do
    value
    |> String.downcase()
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp transaction_amount(transaction) do
    if transaction.withdrawal_paise != 0,
      do: transaction.withdrawal_paise,
      else: transaction.deposit_paise
  end

  defp group_key(fingerprint) do
    fingerprint
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end
end
