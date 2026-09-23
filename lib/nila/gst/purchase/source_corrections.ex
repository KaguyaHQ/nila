defmodule Nila.Gst.Purchase.SourceCorrections do
  @moduledoc "Validates audited purchase-source amount corrections."
  def values(params, row) do
    reason = String.trim(params["reason"] || "")

    parsed =
      for key <- ~w(taxable_paise cgst sgst igst cess total_paise),
          do:
            {key,
             parse_amount(
               if(key == "cess",
                 do:
                   Map.get(params, key, decimal_amount(get_in(row, ["tax_paise", "cess"]) || 0)),
                 else: params[key]
               )
             )}

    cond do
      reason == "" or String.length(reason) > 1000 ->
        {:error, "Enter a reason for this correction."}

      Enum.any?(parsed, fn {_, value} -> value == :error end) ->
        {:error, "Enter non-negative rupee amounts with no more than two decimal places."}

      true ->
        values = Map.new(parsed)

        expected =
          values["taxable_paise"] + values["cgst"] + values["sgst"] + values["igst"] +
            values["cess"]

        if abs(values["total_paise"] - expected) > 100 do
          {:error, "Total must equal taxable value plus GST, allowing up to ₹1 for round-off."}
        else
          heads = Map.take(values, ~w(cgst sgst igst))

          heads =
            if Map.has_key?(row["tax_paise"] || %{}, "cess") or values["cess"] > 0,
              do: Map.put(heads, "cess", values["cess"]),
              else: heads

          {:ok,
           %{
             "taxable_paise" => values["taxable_paise"],
             "total_paise" => values["total_paise"],
             "tax_paise" => heads
           }, reason}
        end
    end
  end

  defp parse_amount(value) when is_binary(value) do
    value = String.trim(value)

    if Regex.match?(~r/\A\d{1,13}(?:\.\d{1,2})?\z/, value) do
      [whole | decimals] = String.split(value, ".")

      String.to_integer(whole) * 100 +
        String.to_integer(String.pad_trailing(List.first(decimals) || "0", 2, "0"))
    else
      :error
    end
  end

  defp parse_amount(_), do: :error

  defp decimal_amount(paise),
    do: "#{div(paise, 100)}.#{String.pad_leading(to_string(rem(paise, 100)), 2, "0")}"

  def attrs(row, values, reason) do
    for {field, value} <- values, row[field] != value do
      %{
        "verb" => "correct_field",
        "books_id" => row["id"],
        "payload" => %{"field" => field, "from" => row[field], "to" => value, "reason" => reason}
      }
    end
  end
end
