defmodule NilaWeb.Components.Gst.Month.Helpers do
  @moduledoc false

  def invoice_issues(issues_by_invoice, invoice) do
    issues_by_invoice[invoice["id"]] || issues_by_invoice[invoice["invoice_number"]] || []
  end

  # A blocking issue is not a louder warning — it is the one thing on the page a
  # reviewer cannot answer, so it reads as an error and stays open. An advisory
  # asserts nothing is wrong and never gates, so it must not wear the same badge
  # as work that withholds the filing.
  def severity_variant("blocking"), do: "error"
  def severity_variant("error"), do: "error"
  def severity_variant("advisory"), do: "neutral"
  def severity_variant("info"), do: "neutral"
  def severity_variant(_), do: "warning"

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
