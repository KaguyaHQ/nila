defmodule Nila.Gst.LineRate do
  @moduledoc "Extracts a line's printed or derived GST rate for validators."

  def line_rate(line) do
    case line_rate_with_source(line) do
      {:ok, rate, _source} -> {:ok, rate}
      :error -> :error
    end
  end

  def line_rate_with_source(line) do
    values = [line["cgst_rate"], line["sgst_rate"], line["igst_rate"]]

    cond do
      Enum.any?(values, &is_number/1) ->
        rate = values |> Enum.map(&if(is_number(&1), do: &1, else: 0)) |> Enum.sum()
        {:ok, Float.round(rate * 1.0, 4), :printed}

      is_integer(line["taxable_paise"]) and line["taxable_paise"] > 0 and
          line_tax(line) > 0 ->
        rate = Float.round(line_tax(line) * 100 / line["taxable_paise"], 4)
        {:ok, rate, :derived}

      true ->
        :error
    end
  end

  defp line_tax(line), do: line["tax_paise"] |> Map.values() |> Enum.sum()
end
