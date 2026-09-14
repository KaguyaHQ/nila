defmodule Nila.Gst.Extraction.InvoicePrompt do
  @moduledoc "Reading instructions shared by invoice extraction routes."
  alias Nila.Gst.Extraction.InvoiceSchema

  @doc "The instruction block for one invoice."
  def base(kind, modality, contract \\ :current)
      when (kind in [:sales, :purchase] and contract == :current) or
             (kind == :sales and contract == :semantic) do
    """
    You are reading the #{source_name(modality)} of ONE #{kind} invoice from an Indian GST bill \
    packet. The pages below are that invoice and nothing else.

    Return exactly one invoice object.

    - Copy printed numbers only into fields matching their role and scope. Normalize \
    currency marks and digit grouping without changing the value. Do not calculate \
    missing numbers, move invoice-summary figures into item rows, or change printed \
    values to make totals agree. For absent or unreadable values, use the schema's \
    absence value: null for nullable fields, [] for absent lists, and unknown for \
    uncertain classifications that allow it. Required objects retain their fields \
    with these absence values. Do not substitute zero or an empty string. \
    Clearly visible handwritten or manually entered values are source evidence too.
    - item_name is the primary printed product/service text in the item's name \
    or description cell. Keep supplementary narrative in description but do not \
    append it to item_name.
    - For every line-level tax type or tax column, copy its printed label, rate \
    and amount into printed_tax_components. Preserve the printed label instead \
    of deciding which canonical GST field it belongs to. Never infer a tax head \
    from party or delivery addresses or accounting rules.
    #{amount_instruction(contract)}\
    - Line and column labels describe their rows; summaries, footer captions and \
    amount-in-words labels describe invoice-level figures.
    - Populate singular invoice-level printed_total_* fields only when that \
    invoice-level aggregate is itself printed. Copy every invoice-level tax total, \
    including generic Tax Amount totals, once into printed_tax_totals. Tax-rate \
    and slab-summary rows are not substitutes for a printed invoice-level aggregate.
    - Represent every real item row. Never turn a subtotal, total, HSN summary or \
    amount-in-words row into a line item. When consecutive printed rows are identical \
    in every other extracted field, return one line item with repeat_count equal to \
    the number of those rows. Otherwise use repeat_count 1. Never combine rows that \
    differ in any extracted field, and never combine non-consecutive rows.
    #{kind_rules(kind)}\
    """
  end

  defp amount_instruction(:semantic) do
    "- Understand the invoice headings and layout. Return amounts shown for each item. Do not calculate missing amounts.\n"
  end

  defp amount_instruction(:current) do
    """
    - line_amount_tax_inclusion is inferred from labels, structure or visible \
    arithmetic. For example, a row amount plus separately printed GST equalling \
    its gross total establishes tax-exclusive pricing. Use unknown when evidence \
    is incomplete or conflicting. Taxable-value calculation belongs to a later step.
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
    using amount in words to clarify an ambiguous reading, not to replace a clearly \
    printed numeric total when the two disagree. Under reverse charge or LUT/bond, \
    the HSN tax summary can show tax which \
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
    labels such as "Credit Note:" or "Debit Note:" from the value. Keep note amounts \
    positive; document_type determines their accounting effect. Signed adjustments \
    retain their own sign, including a negative rounding adjustment when subtracted.
    """
  end

  def build(kind, pages, modality, contract \\ :current) when modality in [:text, :vision] do
    base(kind, modality, contract) <>
      """

      These are physical PDF pages #{Enum.join(pages, ", ")}, in order. #{reading_instruction(modality)}
      Reconcile ambiguous decimal placement and separate rupee/paise columns against
      printed totals and amount in words to disambiguate the visible value.
      Copy printed HSN/SAC codes from descriptions or service ledger names into hsn_sac,
      even without a dedicated HSN/SAC column; never infer an unprinted code.
      For example, "Consulting - 998312 @ 18%" has hsn_sac "998312".

      Each line_items entry must be an array with exactly these fields in this exact order:
      [#{Enum.join(InvoiceSchema.line_item_fields(contract), ", ")}]
      Do not emit field names inside line_items. Preserve nulls so every row has exactly
      #{length(InvoiceSchema.line_item_fields(contract))} values.

      #{amount_examples(contract)}
      """
  end

  @doc false
  def amount_examples(contract \\ :current)

  def amount_examples(:current) do
    """
    Amount mapping examples. These are partial invoice outputs showing only the
    relevant fields; each item uses the complete array order above. Other fields
    still follow the schema. Values in these examples are not invoice data.

    1. Item: Bolt | Qty 10 | Unit price 100 | Taxable price/unit 100 | GST 180 (18%) | Amount 1180.
    Footer: Taxable subtotal 1000. No extended taxable value is printed in the row.
    ```json
    {"line_items":[["Bolt",null,null,10,null,100,null,null,null,1180,null,"unknown",[{"printed_label":"GST","printed_rate":18,"printed_amount":180}],1]],"printed_total_taxable":1000}
    ```

    2. Item: Bolt | Qty 10 | Rate 100 | Amount 1000 | GST 180 (18%) | Total 1180.
    Both a pre-tax row amount and a gross row total are printed.
    ```json
    {"line_items":[["Bolt",null,null,10,null,100,null,null,1000,1180,null,"exclusive",[{"printed_label":"GST","printed_rate":18,"printed_amount":180}],1]]}
    ```

    3. Item: Bolt | Qty 10 | Amount including GST 1180. No separate item tax is printed.
    ```json
    {"line_items":[["Bolt",null,null,10,null,null,null,null,1180,null,null,"inclusive",[],1]]}
    ```

    4. Items: Bolt | Qty 2 | Taxable Value 200; Nut | Qty 1 | Taxable Value 50.
    Footer only: CGST 22.50; SGST 22.50; Invoice Total 295; Paid 100; Balance Due 195.
    Explicit taxable values belong in printed_taxable_value even when they are the
    only row amounts. Footer taxes remain at invoice level; payments do not change
    the printed invoice total.
    ```json
    {"line_items":[["Bolt",null,null,2,null,null,null,null,null,null,200,"unknown",[],1],["Nut",null,null,1,null,null,null,null,null,null,50,"unknown",[],1]],"printed_tax_totals":[{"printed_label":"CGST","printed_amount":22.5},{"printed_label":"SGST","printed_amount":22.5}],"printed_grand_total":295}
    ```
    """
  end

  def amount_examples(:semantic) do
    """
    Amount mapping examples. These are partial invoice outputs showing only the relevant fields; each item uses the complete array order above. Other fields still follow the schema. Values in these examples are not invoice data.

    1. Item: Bolt | Qty 10 | Unit price 100 | Taxable price/unit 100 | GST 180 (18%) | Amount 1180. Footer: Taxable subtotal 1000.
    ```json
    {"line_items":[["Bolt",null,null,10,null,100,null,null,null,1180,[{"printed_label":"GST","printed_rate":18,"printed_amount":180}],1]],"printed_total_taxable":1000}
    ```

    2. Item: Bolt | Qty 10 | Rate 100 | Amount 1000 | GST 180 (18%) | Total 1180.
    ```json
    {"line_items":[["Bolt",null,null,10,null,100,null,null,1000,1180,[{"printed_label":"GST","printed_rate":18,"printed_amount":180}],1]]}
    ```

    3. Item: Bolt | Qty 10 | Amount including GST 1180. No separate item tax is printed.
    ```json
    {"line_items":[["Bolt",null,null,10,null,null,null,null,null,1180,[],1]]}
    ```

    4. Items: Bolt | Qty 2 | Taxable Value 200; Nut | Qty 1 | Taxable Value 50. Footer only: CGST 22.50; SGST 22.50; Invoice Total 295; Paid 100; Balance Due 195.
    ```json
    {"line_items":[["Bolt",null,null,2,null,null,null,null,200,null,[],1],["Nut",null,null,1,null,null,null,null,50,null,[],1]],"printed_tax_totals":[{"printed_label":"CGST","printed_amount":22.5},{"printed_label":"SGST","printed_amount":22.5}],"printed_grand_total":295}
    ```
    """
  end

  def system(:text), do: "You read invoices from PDF text into JSON."
  def system(:vision), do: "You read invoices from page images into JSON."
  defp source_name(:text), do: "PDF text"
  defp source_name(:vision), do: "page images"
  defp reading_instruction(:text), do: "Read the extracted text directly."
  defp reading_instruction(:vision), do: "Read the pixels directly."
end
