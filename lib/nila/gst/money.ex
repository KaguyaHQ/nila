defmodule Nila.Gst.Money do
  @moduledoc """
  Exact GST money conversion.

  Monetary arithmetic inside Nila uses integer paise. Extracted rupee values
  may arrive as integers, floats, or printed strings; conversion happens once
  at the domain boundary and keeps missing and unreadable values distinct.
  """

  @currency_prefix ~r/^(rs\.?|inr|₹)\s*/i
  @grouping ~r/[\s,]/
  @number ~r/^-?\d+(\.\d+)?$/

  @doc "Converts a rupee value to paise, collapsing missing or unreadable input to zero."
  def paise(value) do
    case paise_or_error(value) do
      {:ok, paise} -> paise
      _missing_or_unreadable -> 0
    end
  end

  @doc "Converts rupees to `{:ok, paise}`, `:missing`, or `:unreadable`."
  def paise_or_error(nil), do: :missing
  def paise_or_error(value) when is_integer(value), do: {:ok, value * 100}

  def paise_or_error(value) when is_float(value) do
    value
    |> Decimal.from_float()
    |> decimal_to_paise()
  end

  def paise_or_error(value) when is_binary(value) do
    case String.trim(value) do
      "" -> :missing
      trimmed -> parse_rupee_text(trimmed)
    end
  end

  def paise_or_error(%Decimal{} = value), do: decimal_to_paise(value)
  def paise_or_error(_value), do: :unreadable

  @doc "Converts integer paise to an exact two-decimal `Decimal` rupee value."
  def rupees(paise) when is_integer(paise), do: Decimal.div(Decimal.new(paise), 100)

  defp parse_rupee_text(trimmed) do
    cleaned =
      trimmed
      |> String.replace(@currency_prefix, "")
      |> String.replace(@grouping, "")

    if cleaned != "" and Regex.match?(@number, cleaned) do
      cleaned
      |> Decimal.new()
      |> decimal_to_paise()
    else
      :unreadable
    end
  end

  defp decimal_to_paise(decimal) do
    paise = decimal |> Decimal.mult(100) |> Decimal.round(0) |> Decimal.to_integer()
    {:ok, paise}
  end
end
