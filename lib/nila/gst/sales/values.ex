defmodule Nila.Gst.Sales.Values do
  @moduledoc """
  The named money figures for one sales invoice, and the one rule about which of
  them reaches the portal.

  An invoice's tax reads three ways and every surface used to call all three
  "Tax":

    * `printed` — what the bill's own footer says. Evidence about the document.
    * `extracted_lines` — the sum of the extracted line amounts, unrounded and
      ungrouped. Evidence about the extraction. **Never filed under any action.**
    * `filed` — the per-rate-bucket recomputation `derive/2` puts in the return.

  The third is the only one with consequences, and it is not the sum of the
  second: `computed_bucket_tax/3` rounds per rate bucket, and for an intrastate
  bucket it halves the bucket's taxable value rather than adding the two
  extracted heads. So a rupee-level difference is normal and expected, and a
  *head-level* difference is possible without any total-level difference at all.

  ## Why `filed/2` reads the derived return rather than recomputing

  Recomputing here would produce a fourth number with a fourth opportunity to
  disagree. `derive_invoice/2` decides intrastate-vs-interstate from the two
  GSTINs, while the `printed_*_mismatch` checks decide it per line from whichever
  head the extraction populated. Those disagree on a bill whose GSTINs say
  intrastate and whose lines carry IGST: the check compares 1800 against 1800 and
  passes, while the return files CGST 900 + SGST 900. Nothing on the page said
  so. `head_reassignment/2` is that case, named.

  Every figure here is a float of rupees, matching `Gstr1`'s own arithmetic.
  """

  alias Nila.Gst.Sales.Gstr1

  @heads ~w(igst cgst sgst)a

  # Deliberately tighter than `Gstr1`'s `@money_tolerance` of 0.5. That one asks
  # "is this a mistake worth a reviewer's time?"; this one asks "are these the
  # same number?", and the differences this module exists to name are paise. At
  # 0.5 a bucket-rounding delta and a genuine head reassignment would both read
  # as equal. One float epsilon above a paise.
  @tolerance 0.011

  @doc """
  The five named figures for `invoice`, given the `derived` return it belongs to.

  `derived` is the output of `Gstr1.derive/2` — the same map the draft, the
  export and the sign-off read, so `filed` here cannot drift from what the
  portal receives.
  """
  def for_invoice(invoice, derived) do
    printed = printed(invoice)
    extracted = extracted_lines(invoice)
    filed = filed(invoice, derived)

    %{
      printed: printed,
      extracted_lines: extracted,
      filed: filed,
      liability_effect: scale(filed, Gstr1.document_effect(invoice)),
      # What a reviewer is answering when a `printed_*_mismatch` is open: the
      # footer against the extraction. Both are readings of the document. A
      # field the bill did not print is `nil` here rather than a difference
      # against zero — "the footer says something else" and "there is no footer"
      # are not the same finding, and only one of them is a question.
      printed_vs_extracted: printed_difference(extracted, printed),
      # What the reviewer's decision actually changes in the return. Rounding
      # alone lands in the paise; anything larger is a real regrouping.
      extracted_vs_filed: difference(filed, extracted),
      head_reassignment: head_reassignment(extracted, filed)
    }
  end

  @doc "The month's filed totals, summed from the derived return's own line details."
  def filed_totals(derived) do
    derived
    |> invoice_details()
    |> Enum.reduce(empty(), &add_detail/2)
  end

  @doc """
  The figures `derive/2` filed for one invoice, read back out of the return.

  `nil` when there is no single answer, which is two different situations and
  both must render as "no figure" rather than a number:

    * the invoice is not in the return — excluded as a duplicate copy, or held
      out by a blocker;
    * two invoices share the number, so the return holds two entries and no
      reading of "this invoice's filed tax" is truthful. `duplicate_invoice_number`
      is blocking, so the month cannot be signed in this state — but the modal
      is open during exactly the window when it is unresolved, and summing both
      copies would show a reviewer double the tax while they decide.
  """
  def filed(invoice, derived) do
    case invoice_entries(derived, invoice) do
      [entry] -> entry |> details() |> Enum.reduce(empty(), &add_detail/2)
      _none_or_many -> nil
    end
  end

  @doc "The bill's own footer, or `nil` for the fields it did not print."
  def printed(invoice) do
    %{
      taxable: number(invoice["printed_total_taxable"]),
      tax: number(invoice["printed_total_tax"]),
      total: number(invoice["printed_grand_total"])
    }
  end

  @doc "The unrounded, ungrouped sum of the extracted lines, split by head."
  def extracted_lines(invoice) do
    invoice
    |> List.wrap()
    |> Enum.flat_map(&List.wrap(&1["line_items"]))
    |> Enum.reduce(empty(), fn line, totals ->
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

  defp invoice_entries(nil, _invoice), do: []

  defp invoice_entries(derived, invoice) do
    case Gstr1.document_type(invoice) do
      "credit_note" ->
        for group <- List.wrap(derived["cdnr"]),
            note <- List.wrap(group["nt"]),
            note["nt_num"] == Gstr1.document_number(invoice),
            do: note

      _invoice ->
        for group <- List.wrap(derived["b2b"]),
            entry <- List.wrap(group["inv"]),
            entry["inum"] == Gstr1.document_number(invoice),
            do: entry
    end
  end

  defp details(inv) do
    for itm <- List.wrap(inv["itms"]), det = itm["itm_det"], is_map(det), do: det
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

  defp printed_difference(extracted, printed) do
    %{
      taxable: printed_delta(extracted.taxable, printed.taxable),
      tax: printed_delta(extracted.tax, printed.tax),
      total: printed_delta(extracted.taxable + extracted.tax, printed.total)
    }
  end

  defp printed_delta(_extracted, nil), do: nil
  defp printed_delta(extracted, printed), do: round2(extracted - printed)

  defp scale(nil, _effect), do: nil

  defp scale(totals, effect) do
    Map.new(totals, fn {key, value} -> {key, value * effect} end)
  end

  defp difference(_a, nil), do: nil
  defp difference(nil, _b), do: nil

  defp difference(a, b) do
    %{
      taxable: round2(a.taxable - (b[:taxable] || 0.0)),
      igst: round2(a.igst - (b[:igst] || 0.0)),
      cgst: round2(a.cgst - (b[:cgst] || 0.0)),
      sgst: round2(a.sgst - (b[:sgst] || 0.0)),
      tax: round2(a.tax - (b[:tax] || 0.0))
    }
  end

  defp heads(totals), do: Map.take(totals, @heads)

  defp empty, do: %{taxable: 0.0, igst: 0.0, cgst: 0.0, sgst: 0.0, tax: 0.0}

  defp close?(a, b), do: abs(a - b) <= @tolerance

  defp round2(value), do: Float.round(value / 1, 2)

  defp number(value) when is_number(value), do: value / 1
  defp number(_value), do: nil
end
