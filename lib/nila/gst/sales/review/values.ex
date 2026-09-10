defmodule Nila.Gst.Sales.Review.Values do
  @moduledoc """
  Printed and extracted evidence alongside the source contribution included in
  a GSTR-1 projection. Contributions are keyed by source ID, including documents
  merged into B2CS and nil-supply totals. An absent source has no filed figure.
  """

  alias Nila.Gst.Sales.{Gstr1, Invoice}

  @heads ~w(igst cgst sgst)a

  # Deliberately tighter than `InvoiceValidation`'s ₹0.50 tolerance. That one asks
  # "is this a mistake worth a reviewer's time?"; this one asks "are these the
  # same number?", and the differences this module exists to name are paise. At
  # 0.5 a bucket-rounding delta and a genuine head reassignment would both read
  # as equal. One float epsilon above a paise.
  @tolerance 0.011

  @doc "The named figures for an invoice, given its Gstr1.project/2 result or workings."
  def for_invoice(invoice, projection) do
    printed = printed(invoice)
    extracted = extracted_lines(invoice)
    filed = filed(invoice, projection)

    %{
      printed: printed,
      extracted_lines: extracted,
      filed: filed,
      liability_effect: liability_effect(invoice, projection, filed),
      # What a reviewer is answering when a `printed_*_mismatch` is open: the
      # footer against the extraction. Both are readings of the document. A
      # field the bill did not print is `nil` here rather than a difference
      # against zero — "the footer says something else" and "there is no footer"
      # are not the same finding, and only one of them is a question.
      printed_vs_extracted: printed_difference(extracted, printed, invoice),
      # What the reviewer's decision actually changes in the return. Rounding
      # alone lands in the paise; anything larger is a real regrouping.
      extracted_vs_filed: difference(filed, extracted),
      head_reassignment: head_reassignment(extracted, filed)
    }
  end

  @doc "The month's filed totals, summed from the derived return's own line details."
  def filed_totals(%{derived: derived}), do: filed_totals(derived)

  def filed_totals(derived) do
    derived
    |> invoice_details()
    |> Enum.reduce(empty(), &add_detail/2)
  end

  @doc "The included source contribution, or nil when the source is absent."
  def filed(invoice, %{contributions: contributions}) do
    case Map.get(contributions, invoice["id"]) do
      %{entry: entry} -> entry |> details() |> Enum.reduce(empty(), &add_detail/2)
      nil -> nil
    end
  end

  def filed(_invoice, _without_contributions), do: nil

  @doc "The bill's own footer, or `nil` for the fields it did not print."
  def printed(invoice) do
    %{
      taxable: number(invoice["printed_total_taxable"]),
      tax: Nila.Gst.Extraction.TaxComponents.printed_tax_total(invoice),
      total: number(invoice["printed_grand_total"])
    }
  end

  @doc "The unrounded, ungrouped sum of the extracted lines, split by head."
  def extracted_lines(invoice) do
    lines = invoice |> List.wrap() |> Enum.flat_map(&List.wrap(&1["line_items"]))

    totals =
      Enum.reduce(lines, empty(), fn line, totals ->
        igst = number(line["igst_amount"]) || 0.0
        cgst = number(line["cgst_amount"]) || 0.0
        sgst = number(line["sgst_amount"]) || 0.0

        %{
          totals
          | taxable: totals.taxable + (number(line["taxable_value"]) || 0.0),
            igst: totals.igst + igst,
            cgst: totals.cgst + cgst,
            sgst: totals.sgst + sgst,
            tax: totals.tax + igst + cgst + sgst
        }
      end)

    if Enum.all?(lines, &is_number(&1["taxable_value"])),
      do: totals,
      else: %{totals | taxable: nil}
  end

  @doc """
  The heads the return moved the tax into, when it disagrees with the extraction.

  `nil` when they agree. Non-nil means the portal receives this tax under
  different heads than the bill was read as carrying — an inter/intra-state
  reassignment driven by the two GSTINs, since `derive_invoice/2` picks the mode
  from the GSTINs while the extraction populated whichever head it read. The
  totals can be identical while this is set, which is why no total-level check
  catches it.

  Reports only an actual *reassignment*: the IGST side has to change between
  carrying tax and carrying none. Per-bucket rounding can move a paise between
  CGST and SGST without anything being reassigned, and calling that an
  inter/intra-state change would be a louder claim than the evidence supports.
  """
  def head_reassignment(extracted, filed)
  def head_reassignment(_extracted, nil), do: nil

  def head_reassignment(extracted, filed) do
    moved =
      Enum.reject(@heads, fn head ->
        close?(Map.fetch!(extracted, head), Map.fetch!(filed, head))
      end)

    if moved != [] and mode_flipped?(extracted, filed) do
      %{heads: moved, from: heads(extracted), to: heads(filed)}
    end
  end

  defp mode_flipped?(extracted, filed),
    do: zero?(extracted.igst) != zero?(filed.igst)

  defp zero?(amount), do: abs(amount) <= @tolerance

  @doc """
  The change one resolution makes to the return, stated in the figures it files.

  Takes the derived return before and after, so the effect a proposal claims is
  measured against `derive/2` rather than predicted alongside it. A component
  that computes its own effect is a component that can disagree with the engine.
  """
  def effect(derived_before, derived_after) do
    before_totals = filed_totals(derived_before)
    after_totals = filed_totals(derived_after)

    %{
      before: before_totals,
      after: after_totals,
      change: difference(after_totals, before_totals)
    }
  end

  defp invoice_details(nil), do: []

  defp invoice_details(derived) do
    derived
    |> Gstr1.signed_details()
    |> Enum.map(& &1.detail)
  end

  defp details(inv) do
    for itm <- List.wrap(inv["itms"]), det = itm["itm_det"] || itm, is_map(det), do: det
  end

  defp add_detail(detail, totals) do
    igst = number(detail["iamt"]) || 0.0
    cgst = number(detail["camt"]) || 0.0
    sgst = number(detail["samt"]) || 0.0

    %{
      totals
      | taxable: totals.taxable + (number(detail["txval"]) || 0.0),
        igst: totals.igst + igst,
        cgst: totals.cgst + cgst,
        sgst: totals.sgst + sgst,
        tax: totals.tax + igst + cgst + sgst
    }
  end

  defp printed_difference(extracted, printed, invoice) do
    total =
      if is_number(extracted.taxable),
        do:
          printed_delta(
            extracted.taxable +
              if(Invoice.tax_excluded_from_total?(invoice), do: 0, else: extracted.tax),
            printed.total
          )

    %{
      taxable: printed_delta(extracted.taxable, printed.taxable),
      tax: printed_delta(extracted.tax, printed.tax),
      total: total
    }
  end

  defp printed_delta(_extracted, nil), do: nil
  defp printed_delta(nil, _printed), do: nil
  defp printed_delta(extracted, printed), do: round2(extracted - printed)

  defp liability_effect(invoice, %{contributions: contributions}, filed) do
    case Map.get(contributions, invoice["id"]) do
      %{effect: effect} -> scale(filed, effect)
      nil -> nil
    end
  end

  defp liability_effect(_invoice, _projection, _filed), do: nil

  defp scale(nil, _effect), do: nil

  defp scale(totals, effect) do
    Map.new(totals, fn {key, value} -> {key, value * effect} end)
  end

  defp difference(_a, nil), do: nil
  defp difference(nil, _b), do: nil

  defp difference(a, b) do
    %{
      taxable: component_difference(a.taxable, b[:taxable]),
      igst: component_difference(a.igst, b[:igst]),
      cgst: component_difference(a.cgst, b[:cgst]),
      sgst: component_difference(a.sgst, b[:sgst]),
      tax: component_difference(a.tax, b[:tax])
    }
  end

  defp component_difference(a, b) when is_number(a) and is_number(b), do: round2(a - b)
  defp component_difference(_a, _b), do: nil

  defp heads(totals), do: Map.take(totals, @heads)

  defp empty, do: %{taxable: 0.0, igst: 0.0, cgst: 0.0, sgst: 0.0, tax: 0.0}

  defp close?(a, b), do: abs(a - b) <= @tolerance

  defp round2(value), do: Float.round(value / 1, 2)

  defp number(value) when is_number(value), do: value / 1
  defp number(_value), do: nil
end
