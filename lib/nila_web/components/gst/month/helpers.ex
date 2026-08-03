defmodule NilaWeb.Components.Gst.Month.Helpers do
  @moduledoc false

  def invoice_issues(issues_by_invoice, invoice) do
    issues_by_invoice[invoice["id"]] || issues_by_invoice[invoice["invoice_number"]] || []
  end

  # Blockers lead: they are the only entries nobody on the page can answer.
  @kinds [
    blocked: "blocker",
    decision: "decision",
    confirmation: "confirmation",
    correction: "correction",
    collection: "bill to collect"
  ]

  @doc """
  What is open, named by the work each item asks for: "1 decision · 1 confirmation
  · 7 advisories".

  There is no umbrella noun. "2 items requiring review" is software-speak, and a
  reviewer who is told "9 checks" cannot tell which of them he can actually
  answer. Empty when nothing is open, so a caller can render nothing at all.
  """
  def work_clause(by_kind, advisory_count \\ 0) do
    kinds =
      Enum.flat_map(@kinds, fn {kind, noun} ->
        case Map.get(by_kind, kind, 0) do
          0 -> []
          count -> ["#{count} #{pluralise(count, noun)}"]
        end
      end)

    advisories =
      if advisory_count > 0,
        do: ["#{advisory_count} #{pluralise(advisory_count, "advisory")}"],
        else: []

    Enum.join(kinds ++ advisories, " · ")
  end

  def pluralise(1, noun), do: noun
  def pluralise(_count, "advisory"), do: "advisories"
  def pluralise(_count, "bill to collect"), do: "bills to collect"
  def pluralise(_count, noun), do: noun <> "s"

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
