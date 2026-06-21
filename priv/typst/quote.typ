// Quotation document — composes the shared Nila layout (_shared.typ). Every
// value arrives pre-formatted from Nila.Quotes.Pdf; see Nila.Typst for how the
// data is injected (as `json("data.json")`, passed to `main` below).

#import "_shared.typ": *

#let main(data) = {
  show: document-frame.with(
    title: data.doc.label,
    author: data.supplier.name,
    footer-note: data.footer_note,
  )

  letterhead(data.supplier, data.doc.kind, data.doc.label)

  ref-strip((
    ("Quote date", data.doc.quote_date),
    ("Valid until", data.doc.valid_until),
    ("Place of supply", data.doc.place_of_supply),
    ("GST treatment", data.doc.gst_treatment),
  ))

  v(1.8em)

  two-col(
    party(
      "Bill to",
      data.bill_to.name,
      data.bill_to.address,
      gstin: data.bill_to.gstin,
      state: data.bill_to.state,
    ),
    if data.ship_to.same_as_bill {
      party("Ship to", "Same as billing", none)
    } else {
      party("Ship to", data.ship_to.name, data.ship_to.address, state: data.ship_to.state)
    },
  )

  if data.doc.subject != none {
    v(1.4em)
    label-text("Subject")
    v(0.4em)
    text(size: 9.5pt, weight: "medium")[#data.doc.subject]
  }

  v(1.6em)

  items-table(data.line_items, "This quote has no line items yet.")

  v(1.4em)

  totals-band(
    (("Subtotal", data.totals.subtotal),) +
      data.totals.tax_rows.map(row => (row.label, row.value)),
    data.totals.grand_total,
    in-words: if data.line_items.len() != 0 { data.totals.in_words },
  )

  v(3em)
  signature(data.signatory_for)
}
