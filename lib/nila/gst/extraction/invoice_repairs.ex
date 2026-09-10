defmodule Nila.Gst.Extraction.InvoiceRepairs do
  @moduledoc "Repairs extracted invoice candidates and records the evidence for each change."

  alias Nila.Gst.{LineAmounts, TaxComponents}
  alias Nila.Gst.Money
  alias Nila.Gstin

  @doc "Applies the provider-independent repairs shared by text and vision extraction."
  def prepare(data, kind, client_gstin) do
    {data, repairs} =
      data
      |> TaxComponents.project()
      |> expand_repeated_line_items()
      |> markers(kind)
      |> repair_gstins(kind, client_gstin)

    {data, redundant} = discard_redundant_taxable_candidates(data)
    {data, repairs ++ redundant}
  end

  defp discard_redundant_taxable_candidates(data) do
    {lines, repairs} =
      data
      |> Map.get("line_items", [])
      |> Enum.with_index()
      |> Enum.map_reduce([], fn {line, index}, repairs ->
        case discard_redundant_printed_taxable(line) do
          {line, nil} ->
            {line, repairs}

          {line, repair} ->
            repair = Map.update!(repair, "field", &"line_items[#{index}].#{&1}")
            {line, repairs ++ [repair]}
        end
      end)

    {Map.put(data, "line_items", lines), repairs}
  end

  defp markers(data, :purchase) do
    data
    |> Map.put("is_invoice", true)
    |> Map.put("continuation_of_previous", false)
  end

  defp markers(data, :sales), do: data

  @doc """
  Clears an equal taxable candidate when row arithmetic proves exclusive pricing.
  This extraction repair changes the input and returns an audit record; `LineAmounts.normalize/1`
  only interprets it. Equality is checked in paise, not with arithmetic tolerance.
  """
  def discard_redundant_printed_taxable(line) when is_map(line) do
    amounts = LineAmounts.normalize(line)

    if is_number(amounts.printed_taxable_value) and is_number(amounts.printed_line_amount) and
         Money.paise(amounts.printed_taxable_value) == Money.paise(amounts.printed_line_amount) and
         amounts.line_amount_tax_inclusion == "exclusive" and
         amounts.line_amount_tax_inclusion_basis in ~w(line_amount_plus_tax_equals_total line_amount_times_rate_equals_tax) do
      repair = %{
        "field" => "printed_taxable_value",
        "from" => amounts.printed_taxable_value,
        "to" => nil,
        "basis" => "redundant_with_arithmetically_exclusive_line_amount"
      }

      {Map.put(line, "printed_taxable_value", nil), repair}
    else
      {line, nil}
    end
  end

  @doc false
  def expand_repeated_line_items(data) do
    Map.update!(data, "line_items", fn lines ->
      Enum.flat_map(lines, fn line ->
        count = Map.fetch!(line, "repeat_count")

        if is_integer(count) and count in 1..1_000 do
          List.duplicate(Map.delete(line, "repeat_count"), count)
        else
          raise ArgumentError, "invalid repeat_count: #{inspect(count)}"
        end
      end)
    end)
  end

  @doc """
  Repairs GSTINs the scanner damaged, on evidence, and records every repair.

  Two oracles, both stronger than the model's own reading:

    * the **format itself** — `Nila.Gstin.repair/1` corrects a damaged GSTIN
      when the fixed grammar plus the check digit leave exactly one legal
      reading, and refuses when they leave two;
    * the **known client** — every page of a client's own packet prints their
      own GSTIN, so a field that fails its check digit next to a near-identical
      known value is a scan artefact, not a different company. The threshold is
      deliberately high, and it applies to the client's own side only (buyer on
      a purchase packet, seller on a sales one): that identity is a fact we hold
      independently, the counterparty's is not.

  Left alone otherwise. An invalid GSTIN nobody can resolve stays invalid and
  the verifier flags it, which is the correct outcome — the alternative is a
  purchase attributed to a supplier who does not exist.
  """
  def repair_gstins(data, kind, client_gstin) do
    {seller_key, buyer_key} = party_keys(kind)

    {seller, seller_repair} =
      repair_party(
        data[seller_key],
        "#{seller_key}.gstin",
        known(kind, :seller, client_gstin)
      )

    {buyer, buyer_repair} =
      repair_party(data[buyer_key], "#{buyer_key}.gstin", known(kind, :buyer, client_gstin))

    data =
      data
      |> maybe_put(seller_key, seller)
      |> maybe_put(buyer_key, buyer)

    {data, Enum.reject([seller_repair, buyer_repair], &is_nil/1)}
  end

  # The client is the buyer on their own purchase packet and the seller on their
  # own sales packet. Only the side we hold independently may be snapped to:
  # snapping the other side would rewrite a counterparty's identity from a
  # value that has nothing to do with them. On a sales packet that is not a
  # hypothetical — the customer's GSTIN changes every bill while the client's
  # does not, so a buyer-snapping rule would smear the client's own number
  # across their customers.
  defp known(:purchase, :buyer, gstin), do: gstin
  defp known(:sales, :seller, gstin), do: gstin
  defp known(_kind, _party, _gstin), do: nil

  defp party_keys(:purchase), do: {"seller", "buyer"}
  defp party_keys(:sales), do: {"supplier", "bill_to"}

  defp maybe_put(data, _key, nil), do: data
  defp maybe_put(data, key, value), do: Map.put(data, key, value)

  defp repair_party(party, field, known) when is_map(party) do
    case repair_gstin(party["gstin"], known) do
      nil ->
        {party, nil}

      {repaired, basis} ->
        {Map.put(party, "gstin", repaired), repair(field, party["gstin"], repaired, basis)}
    end
  end

  defp repair_party(party, _field, _known), do: {party, nil}

  defp repair_gstin(value, known) when is_binary(value) and value != "" do
    case Gstin.repair(value) do
      {:ok, _valid} -> nil
      {:repaired, repaired} -> {repaired, "grammar_and_check_digit"}
      :error -> snap_to_known(value, known)
    end
  end

  defp repair_gstin(_value, _known), do: nil

  @similarity 0.8

  defp snap_to_known(value, known) when is_binary(known) do
    if String.jaro_distance(String.upcase(value), known) >= @similarity do
      {known, "known_client"}
    end
  end

  defp snap_to_known(_value, _known), do: nil

  defp repair(field, from, to, basis) do
    %{"field" => field, "from" => from, "to" => to, "basis" => basis}
  end
end
