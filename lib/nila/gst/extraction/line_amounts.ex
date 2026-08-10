defmodule Nila.Gst.Extraction.LineAmounts do
  @moduledoc false

  @bases ~w(inclusive exclusive unknown)

  def normalize(line) when is_map(line) do
    printed_unit_price = money(evidence_value(line, "printed_unit_price", "unit_price"))
    printed_line_amount = money(printed_line_amount(line))
    printed_taxable_value = money(printed_taxable_value(line))
    amount_tax_basis = amount_tax_basis(line)
    rate = rate(line)

    {taxable_value, taxable_value_basis} =
      case {line["taxable_value_basis"], money(line["taxable_value"])} do
        {"corrected", corrected} when is_number(corrected) ->
          {corrected, "corrected"}

        _not_corrected ->
          taxable_value(printed_taxable_value, printed_line_amount, amount_tax_basis, rate)
      end

    %{
      printed_unit_price: printed_unit_price,
      printed_line_amount: printed_line_amount,
      printed_taxable_value: printed_taxable_value,
      amount_tax_basis: amount_tax_basis,
      taxable_value: taxable_value,
      taxable_value_basis: taxable_value_basis
    }
  end

  def taxable_value(line) when is_map(line), do: normalize(line).taxable_value

  defp printed_line_amount(line) do
    if Map.has_key?(line, "printed_line_amount") do
      line["printed_line_amount"]
    else
      line["tax_inclusive_value"]
    end
  end

  defp printed_taxable_value(line) do
    cond do
      Map.has_key?(line, "printed_taxable_value") -> line["printed_taxable_value"]
      line["taxable_value_basis"] in ~w(corrected derived_from_tax_inclusive_value) -> nil
      true -> line["taxable_value"]
    end
  end

  defp evidence_value(line, current, previous) do
    if Map.has_key?(line, current), do: line[current], else: line[previous]
  end

  defp amount_tax_basis(%{"amount_tax_basis" => basis}) when basis in @bases, do: basis
  defp amount_tax_basis(%{"tax_inclusive" => true}), do: "inclusive"
  defp amount_tax_basis(_line), do: "unknown"

  defp taxable_value(printed, _line_amount, _basis, _rate) when is_number(printed),
    do: {printed, "printed_taxable_value"}

  defp taxable_value(nil, line_amount, "inclusive", rate)
       when is_number(line_amount) and rate > 0 do
    {round2(line_amount / (1 + rate / 100)), "derived_from_inclusive_line_amount"}
  end

  defp taxable_value(nil, line_amount, "exclusive", _rate) when is_number(line_amount),
    do: {line_amount, "printed_exclusive_line_amount"}

  defp taxable_value(_printed, _line_amount, _basis, _rate), do: {nil, nil}

  defp rate(line) do
    num(line["cgst_rate"]) + num(line["sgst_rate"]) + num(line["igst_rate"])
  end

  defp money(nil), do: nil
  defp money(value) when is_number(value), do: value

  defp money(value) when is_binary(value) do
    value = String.replace(value, ~r/[^0-9.\-]/, "")

    case Float.parse(value) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp money(_value), do: nil
  defp num(value), do: money(value) || 0
  defp round2(value), do: Float.round(value / 1, 2)
end
