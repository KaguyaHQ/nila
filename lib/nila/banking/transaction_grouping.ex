defmodule Nila.Banking.TransactionGrouping do
  @moduledoc """
  Builds conservative bank-transaction groups that can share one ledger decision.

  V1 groups only UPI transactions with the same direction, normalized payee identity,
  and exact residual narration after known bank references are removed. False negatives
  are intentional: the same payee is not enough evidence for the same accounting ledger.
  """

  alias Nila.Banking.Transaction

  @upi_handle ~r/^(.*?)[-\/]([A-Z0-9._]+@[A-Z0-9 ]+)(.*)$/
  @ifsc ~r/^[A-Z]{4}0[A-Z0-9]{6}$/
  @long_number ~r/^\d{6,}$/
  @generic_patterns ~w(NA UPI PAYMENT TRANSFER)

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

    with true <-
           String.starts_with?(normalized, "UPI-") or String.starts_with?(normalized, "UPI/"),
         [_, prefix, handle, tail] <- Regex.run(@upi_handle, normalized),
         payee when payee != "" <- payee(prefix),
         handle when handle != "" <- compact(handle),
         pattern when pattern != "" <- stable_pattern(tail),
         false <- compact(pattern) in @generic_patterns do
      %{
        fingerprint: {:upi, transaction.transaction_type, handle, compact(pattern)},
        payee: humanize(payee),
        pattern: pattern,
        transaction: transaction
      }
    else
      _ -> nil
    end
  end

  defp candidate(_transaction), do: nil

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
