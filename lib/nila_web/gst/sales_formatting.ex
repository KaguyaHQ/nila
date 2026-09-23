defmodule NilaWeb.Gst.SalesFormatting do
  @moduledoc "Amount and rate labels for sales API responses."

  def rupees(value) when is_number(value),
    do: Nila.Formatters.format_money_with_paise(round(value * 100))

  def rupees(_value), do: "—"

  # Bare grouped figure for arithmetic claims ("15,200 × 18% = 2,736") — the ₹
  # would repeat on every operand and add nothing.
  def amount(value) when is_number(value), do: value |> rupees() |> String.replace("₹", "")
  def amount(_value), do: "—"

  def percent(rate) when is_number(rate) do
    if rate == trunc(rate), do: "#{trunc(rate)}%", else: "#{rate}%"
  end

  def percent(_rate), do: "—"
end
