defmodule Nila.Gst.Extraction.InvoicePrompt do
  @moduledoc "Reading instructions shared by invoice extraction routes."
  alias Nila.Gst.Extraction.InvoiceSchema

  @doc "The instruction block for one invoice."
  def base(kind, modality) do
    """
    You are reading the #{source_name(modality)} of ONE #{kind} invoice from an Indian GST bill \
    packet. The pages below are that invoice and nothing else.

    Return exactly one invoice object.

    - Preserve the economic value of printed numbers. Normalize currency marks \
    and digit grouping as required by the numeric schema, but never replace a \
    printed value with a calculation. If a field is not on these pages, return \
    null. A fabricated number is worse than a missing one and will be caught.
    - item_name is the primary printed product/service text in the item's name \
    or description cell. Keep supplementary narrative in description but do not \
    append it to item_name.
    - Preserve each printed figure in its own role: printed_unit_price is one \
    unit's rate; printed_line_amount is the row's extended amount; \
    printed_line_total is its gross total after separately shown tax; \
    printed_taxable_value is a distinct source field that separately prints the \
    pre-GST value. Never duplicate printed_line_amount into \
    printed_taxable_value merely because the line amount is tax-exclusive.
    - For every line-level tax type or tax column, copy its printed label, rate \
    and amount into printed_tax_components. Preserve the printed label instead \
    of deciding which canonical GST field it belongs to. Never infer a tax head \
    from party or delivery addresses or accounting rules.
    - Arithmetic may classify what a printed amount means. For example, a row \
    amount plus separately printed GST equalling its gross total establishes \
    tax-exclusive pricing. Never use arithmetic to populate any extracted \
    numeric field — including quantities, rates, discounts, taxable values or \
    tax amounts — unless that value itself appears on the document. \
    line_amount_tax_inclusion is an inferred semantic field, not a printed number.
    - Respect scope: line and column labels describe their rows; summaries, \
    footer captions and amount-in-words labels describe invoice-level figures. \
    Never assign a summary figure to a line unless it is independently printed \
    there. Clearly visible handwritten or manually entered values are source \
    evidence too.
    - Set line_amount_tax_inclusion from labels, structure or visible arithmetic. \
    Use unknown when evidence is incomplete or conflicting. Do not calculate \
    taxable_value; a later deterministic step does that.
    - Populate singular invoice-level printed_total_* fields only when that \
    invoice-level aggregate is itself printed. Copy every invoice-level tax total, \
    including generic Tax Amount totals, once into printed_tax_totals. Never \
    select, combine or sum tax-rate or \
    slab-summary rows to create an aggregate, and never redistribute summary \
    figures across item rows.
    - Represent every real item row. Never turn a subtotal, total, HSN summary or \
    amount-in-words row into a line item. When consecutive printed rows are identical \
    in every other extracted field, return one line item with repeat_count equal to \
    the number of those rows. Otherwise use repeat_count 1. Never combine rows that \
    differ in any extracted field, and never combine non-consecutive rows.
    - The invoice may be internally inconsistent — its own printed total may \
    disagree with its lines. Copy what is printed anyway; a later check names \
    the discrepancy.
    #{kind_rules(kind)}\
    """
  end

  # The former sales prompt carried two clauses this stage must not lose. A
  # cancelled invoice still occupies its number, and a return that omits it
  # reports a gap in the series it cannot explain. And an intra-state bill that
  # prints CGST and SGST as stacked sub-rows under each item will, if those are
  # read as two items, be filed at half its rate — the documented invoice-27
  # failure in `Nila.Gst.Sales.Gstr1`.
  defp kind_rules(:sales) do
    """
    - Classify the document itself as invoice, credit_note or debit_note. A title \
    reading CREDIT NOTE or DEBIT NOTE controls; footer terms that merely mention \
    notes do not.
    - For a credit or debit note, invoice_number is the note number only. Exclude \
    labels such as "Credit Note:" from the value.
    - Include cancelled invoices. A cancelled number is still a number the \
    series has to account for, and classify its document_status as cancelled so \
    it cannot be filed as an active taxable invoice.
    - A printed recipient GSTIN means recipient_registration is registered. Use \
    unregistered only when the document positively identifies an unregistered or \
    consumer recipient. A missing or unreadable GSTIN alone is unknown, never a \
    silent B2C inference.
    - Read supplier, Bill To and Ship To/Deliver To into their matching fields.
    - Preserve nil-rated, exempt, non-GST, export and SEZ treatment in supply_type. \
    Never coerce one of them to an ordinary taxable sale.
    - For export/SEZ read tax_payment from the endorsement: on payment of IGST \
    or under LUT/bond without payment of IGST. A combined export/SEZ endorsement \
    with an Indian GSTIN recipient indicates SEZ; a foreign recipient indicates \
    export. Do not classify ordinary foreign-address sales as exports without \
    supporting supply evidence. Preserve printed tax breakdowns even if the \
    endorsement says without payment and the payable total excludes those taxes.
    - Copy printed_grand_total literally from the invoice Total / Amount Chargeable, \
    checking the amount in words. Never replace it with taxable plus the HSN tax \
    summary. Under reverse charge or LUT/bond, that summary can show tax which \
    is NOT added to the amount payable. Read the reverse-charge statement below \
    the tax summary as well as the heading.
    - CGST and SGST printed as stacked sub-rows under one item are two printed \
    tax components of that item, not two items. Never split them, and never split \
    a total row.
    """
  end

  defp kind_rules(:purchase) do
    """
    - Classify the supplier document itself as invoice, credit_note or debit_note. \
    A title reading CREDIT NOTE or DEBIT NOTE controls; footer terms that merely \
    mention notes do not.
    - For a credit or debit note, invoice_number is the note number only. Exclude \
    labels such as "Credit Note:" or "Debit Note:" from the value. Keep every \
    printed amount positive; document_type determines its accounting effect.
    """
  end

  def direct(kind, pages, modality) when modality in [:text, :vision] do
    base(kind, modality) <>
      """

      These are physical PDF pages #{Enum.join(pages, ", ")}, in order. #{reading_instruction(modality)}
      Interpret ordinary numeric Indian invoice dates as DD/MM/YYYY, never MM/DD/YYYY,
      and preserve the printed date text in invoice_date.
      Reconcile ambiguous decimal placement and separate rupee/paise columns against
      printed totals and amount in words. Reconciliation may disambiguate a visible
      value; it must not invent a value absent from the document.
      Set reverse_charge true only when the document positively states that tax is
      payable under reverse charge, false when it explicitly says no, and null otherwise.
      Copy printed HSN/SAC codes from descriptions or service ledger names into hsn_sac,
      even without a dedicated HSN/SAC column; never infer an unprinted code.
      For example, "Consulting - 998312 @ 18%" has hsn_sac "998312".

      Each line_items entry must be an array with exactly these fields in this exact order:
      [#{Enum.join(InvoiceSchema.line_item_fields(), ", ")}]
      Do not emit field names inside line_items. Preserve nulls so every row has exactly
      #{length(InvoiceSchema.line_item_fields())} values.
      """
  end

  def system(:text), do: "You read invoices from PDF text into JSON."
  def system(:vision), do: "You read invoices from page images into JSON."
  defp source_name(:text), do: "PDF text"
  defp source_name(:vision), do: "page images"
  defp reading_instruction(:text), do: "Read the extracted text directly."
  defp reading_instruction(:vision), do: "Read the pixels directly."
end
