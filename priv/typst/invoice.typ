// Tax invoice document — composes the shared Nila layout (_shared.typ), adding
// the invoice organs: copy marking, the AP-matching reference rows (PO, vendor
// code, due date), bank details, and the declaration. Every value arrives
// pre-formatted from Nila.Invoices.Pdf; this file positions text only.

#import "_shared.typ": *

#let main(data) = {
  show: document-frame.with(
    title: data.doc.label,
    author: data.supplier.name,
    footer-note: data.footer_note,
  )

  letterhead(data.supplier, data.doc.kind, data.doc.label, marking: data.doc.marking)

  // Facts row: always shown, hyphens for blanks.
  ref-strip(
    (
      ("Invoice date", data.doc.invoice_date),
    ) + (
      if data.doc.due_date != none { (("Due date", data.doc.due_date),) } else { () }
    ) + (
      ("Place of supply", data.doc.place_of_supply),
      ("GST treatment", data.doc.gst_treatment),
      ("Reverse charge", data.doc.reverse_charge),
    )
  )

  // AP-matching row: only the references that exist; row collapses when none do.
  {
    let refs = ()
    if data.po.number != none { refs += (("PO number", data.po.number),) }
    if data.po.date != none { refs += (("PO date", data.po.date),) }
    if data.vendor_code != none { refs += (("Vendor code", data.vendor_code),) }
    if refs.len() > 0 {
      v(1.2em)
      ref-strip(refs)
    }
  }

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
    } else if data.ship_to.present {
      party("Ship to", data.ship_to.name, data.ship_to.address, state: data.ship_to.state)
    } else {
      []
    },
  )

  v(1.6em)

  items-table(data.line_items, "This invoice has no line items.")

  v(1.4em)

  totals-band(
    (("Subtotal", data.totals.subtotal),) +
      data.totals.tax_rows.map(row => (row.label, row.value)),
    data.totals.grand_total,
    in-words: if data.line_items.len() != 0 { data.totals.in_words },
  )

  v(2.6em)

  // Bank details left, signature right; declaration spans beneath.
  grid(
    columns: (1fr, auto),
    gutter: 3em,
    align: (left + top, right + bottom),
    if data.bank != none {
      [
        #label-text("Pay by NEFT / RTGS")
        #v(0.5em)
        #grid(
          columns: (auto, auto),
          column-gutter: 1.2em,
          row-gutter: 0.45em,
          ..(
            ("Account name", data.bank.holder),
            ("Bank", data.bank.bank),
            ("Account number", data.bank.account),
            ("IFSC", data.bank.ifsc),
          )
            .filter(((k, value)) => value != none)
            .map(((k, value)) => (
              text(size: 8.5pt, fill: muted)[#k],
              text(size: 8.5pt, weight: "medium")[#value],
            ))
            .flatten(),
        )
      ]
    } else {
      []
    },
    signature(data.signatory_for),
  )

  v(1.6em)
  text(size: 7.5pt, fill: faint)[#data.declaration]
}
