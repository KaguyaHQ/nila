defmodule Nila.Gst.Extraction.Discovery.Features do
  @moduledoc """
  Cheap, deterministic signals read off one page's text.

  These were first written as a *segmenter* — a state machine that decided where
  invoices began and ended from the signals alone. On the breeze 2026-06 packet
  it placed 28 of 28 pages and got roughly four of them wrong, and every error
  was silent: two invoices merged because neither printed the word "Total" where
  the regex looked, one invoice split because its continuation page repeated the
  header, invoice numbers captured out of a Tally label grid that were plainly
  not invoice numbers. Heuristics over Indian bill layouts do not fail loudly;
  they fail *confidently*, and a confident wrong boundary is exactly the silent
  error the whole pipeline is being rebuilt to remove.

  So they are demoted here to what they are actually good at: **features for a
  decider and inputs to a verifier**. A GSTIN with a valid check digit is a fact.
  "This page contains the string 275,000" is a fact. "This page starts an
  invoice" is a judgement, and judgement belongs to `Nila.Gst.Extraction.Discovery`'s
  model call, which is then held to the facts.
  """

  alias Nila.Gstin

  @gstin ~r/\b\d{2}[A-Z]{5}\d{4}[A-Z][A-Z\d]Z[A-Z\d]\b/
  @invoice_label ~r/\b(invoice|bill|inv)\s*\.?\s*(no|number|num|#)\b/i
  @dateish ~r/^\d{1,2}[-.\/]\w{1,9}[-.\/]\d{2,4}$/
  @date ~r/\b\d{1,2}[.\/-]\d{1,2}[.\/-]\d{2,4}\b/
  @header ~r/\b(tax\s+invoice|proforma|bill\s+of\s+supply|invoice)\b/i
  @total_row ~r/\b(grand\s+total|amount\s+chargeable)\b|^\|(?:[^|\n]*\|)*\s*\**\s*total\s*\**\s*\|[^\n]*\d/im
  @words ~r/\b(rupees|amount.{0,20}in\s+words|only)\b/i
  @table_header ~r/\|[^|\n]*(descr|particular|hsn|sac)[^|\n]*\|/i
  @table_row ~r/^\|.*\|$/m
  @non_invoice ~r/\b(delivery\s+challan|e-?way\s+bill|purchase\s+order|quotation|packing\s+list|bank\s+statement|payment\s+advice|trip\s+details|order\s+fare)\b/i
  @tax_words ~r/\b(cgst|sgst|igst|taxable\s+value)\b/i

  @doc "Every signal for one page's text."
  def scan(markdown) when is_binary(markdown) do
    gstins = @gstin |> Regex.scan(markdown) |> Enum.map(&List.first/1) |> Enum.uniq()

    %{
      invoice_no: invoice_number(markdown),
      gstins: gstins,
      gstins_valid: Enum.filter(gstins, &Gstin.valid?/1),
      header?: Regex.match?(@header, markdown),
      date?: Regex.match?(@date, markdown),
      table_header?: Regex.match?(@table_header, markdown),
      table_rows: length(Regex.scan(@table_row, markdown)),
      total_row?: Regex.match?(@total_row, markdown),
      tax_words?: Regex.match?(@tax_words, markdown),
      words?: Regex.match?(@words, markdown),
      non_invoice_marker: non_invoice_marker(markdown),
      chars: markdown |> String.trim() |> String.length()
    }
  end

  defp non_invoice_marker(markdown) do
    case Regex.run(@non_invoice, markdown) do
      [_match, marker | _rest] -> String.downcase(marker)
      _none -> nil
    end
  end

  @doc """
  A candidate invoice number: the value a label points at, if it looks like one.

  Tally-style layouts print the label and the value in different table cells, so
  a same-line regex captures the next label instead ("Dated 8-Jun-26 Mode/Terms
  ..."). This walks the grid — right along the label's row, then the rows below
  the label's column — and rejects anything that fails `plausible?/1`. It is a
  candidate, never a verdict: the model may name a different number, and then
  grounding decides which of the two is actually on the page.
  """
  def invoice_number(markdown) do
    lines = String.split(markdown, "\n")

    lines
    |> Enum.with_index()
    |> Enum.find_value(fn {line, index} ->
      if Regex.match?(@invoice_label, line), do: from_label(lines, line, index)
    end)
  end

  defp from_label(lines, line, index) do
    if String.contains?(line, "|") do
      from_cell(lines, line, index)
    else
      lines
      |> Enum.slice(index + 1, 2)
      |> Enum.find_value(&plausible(&1))
    end
  end

  defp from_cell(lines, line, index) do
    cells = cells(line)

    case Enum.find_index(cells, &Regex.match?(@invoice_label, &1)) do
      nil ->
        nil

      column ->
        right = cells |> Enum.drop(column + 1) |> Enum.find_value(&plausible/1)
        right || below(lines, index, column)
    end
  end

  # The value row may not be the next line: markdown separator rows (`|---|---|`)
  # sit between a header and its body. Skip those, then read the label's own
  # column first and the rest of the row as a fallback.
  defp below(lines, index, column) do
    lines
    |> Enum.slice(index + 1, 3)
    |> Enum.reject(&separator_row?/1)
    |> Enum.find_value(fn line ->
      if String.contains?(line, "|") do
        cells = cells(line)

        cells |> Enum.slice(column, 2) |> Enum.find_value(&plausible/1) ||
          Enum.find_value(cells, &plausible/1)
      end
    end)
  end

  defp separator_row?(line) do
    trimmed = String.trim(line)
    trimmed != "" and String.replace(trimmed, ~r/[|\-: ]/, "") == ""
  end

  defp cells(line) do
    line
    |> String.trim()
    |> String.trim("|")
    |> String.split("|")
    |> Enum.map(&String.trim/1)
  end

  @doc "Whether a captured token could be an invoice number at all."
  def plausible(token) when is_binary(token) do
    token = token |> String.trim() |> String.trim(":") |> String.trim("*") |> String.trim()

    cond do
      String.length(token) < 3 or String.length(token) > 20 -> nil
      String.contains?(token, " ") -> nil
      not String.match?(token, ~r/\d/) -> nil
      Regex.match?(@dateish, token) -> nil
      true -> token
    end
  end

  def plausible(_token), do: nil

  @doc "One line per page for the decider's prompt — the facts, compactly."
  def summary(features) do
    [
      "gstin_valid=#{length(features.gstins_valid)}/#{length(features.gstins)}",
      "header=#{yn(features.header?)}",
      "date=#{yn(features.date?)}",
      "table_header=#{yn(features.table_header?)}",
      "rows=#{features.table_rows}",
      "total_row=#{yn(features.total_row?)}",
      "amount_in_words=#{yn(features.words?)}",
      "chars=#{features.chars}"
    ]
    |> then(fn parts ->
      parts ++
        List.wrap(features.invoice_no && "invoice_no_candidate=#{features.invoice_no}") ++
        List.wrap(
          features.non_invoice_marker && "non_invoice_marker=#{features.non_invoice_marker}"
        )
    end)
    |> Enum.join(" ")
  end

  defp yn(true), do: "yes"
  defp yn(false), do: "no"
end
