// The JSON contains an immutable, server-calculated invoice snapshot.
// Values are inserted as text, never evaluated as Typst source.
#let data = json("invoice.json")
#let ink = rgb("20252b")
#let muted = rgb("616a73")
#let rule = rgb("dce0e3")
#let credit = data.document_type == "credit_note"
#let quotation = data.document_type == "quotation"
#let label(value) = text(size: 8pt, fill: muted)[#value]
#let value(value) = if value != none and value != "" { [#value] }

#set document(title: data.number, author: data.supplier.name)
#set page("a4", margin: (x: 18mm, top: 18mm, bottom: 19mm), footer: context [
  #set text(size: 8pt, fill: muted)
  #grid(columns: (1fr, auto), [#data.number], [#counter(page).display() / #counter(page).final().first()])
])
#set text(font: ("Switzer", "Inter"), size: 9pt, fill: ink)
#set par(leading: 0.5em)
// Switzer has no rupee glyph. Match Inter's cap height and separate the amount.
#show "₹": it => [#text(font: "Inter", size: 0.96em)[₹]#h(0.1em)]

#grid(columns: (1fr, 58mm), gutter: 18pt,
  [
    #if data.supplier.at("logo_file", default: none) != none [
      #grid(columns: (22mm, 1fr), gutter: 8pt,
        image(data.supplier.logo_file, width: 22mm, height: 13mm, fit: "contain"),
        text(size: 19pt, weight: "semibold")[#data.supplier.name],
      )
    ] else [
      #text(size: 19pt, weight: "semibold")[#data.supplier.name]
    ]
    #v(8pt)
    #text(size: 8.5pt, fill: muted)[#data.supplier.address]
    #v(4pt)
    GSTIN #data.supplier.gstin
    #if data.supplier.at("phone", default: none) not in (none, "") [
      #v(4pt)
      #data.supplier.phone
    ]
    #if data.supplier.at("email", default: none) not in (none, "") [
      #v(3pt)
      #data.supplier.email
    ]
  ],
  align(right)[
    #label(if quotation { "QUOTATION" } else if credit { "CREDIT NOTE" } else { "TAX INVOICE" })
    #v(6pt)
    #text(size: 17pt, weight: "medium")[#data.number]
    #if data.at("revised_from_number", default: none) not in (none, "") [
      #v(4pt)
      #label("Revised from") #data.revised_from_number
    ]
    #v(8pt)
    #label(if quotation or data.at("draft", default: false) { "Date" } else { "Issued" }) #data.invoice_date
    #if quotation and data.at("valid_until", default: none) != none [
      #v(4pt)
      #label("Valid until") #data.valid_until
    ]
    #if not quotation and data.at("due_date", default: none) != none [
      #v(4pt)
      #label("Due") #data.due_date
    ]
    #if data.at("purchase_order_number", default: none) not in (none, "") [
      #v(6pt)
      #label("Reference / PO No.") #data.purchase_order_number
    ]
    #if data.at("purchase_order_date", default: none) != none [
      #v(4pt)
      #label("Reference date") #data.purchase_order_date
    ]
  ],
)
#v(11pt)
#line(length: 100%, stroke: 0.7pt + rule)
#v(10pt)
#grid(columns: (1fr, 58mm), gutter: 18pt,
  [
    #label(if quotation { "PREPARED FOR" } else { "BILL TO" })
    #v(6pt)
    #text(weight: "semibold")[#data.customer.name]
    #v(4pt)
    #value(data.customer.address)
    #if data.customer.at("state_code", default: none) not in (none, "") [
      #v(4pt)
      State #data.customer.state_code
    ]
    #if data.customer.at("gstin", default: none) != none and data.customer.gstin != "" [
      #v(4pt)
      GSTIN #data.customer.gstin
    ]
  ],
  [
    #if data.at("delivery_address", default: none) not in (none, "") [
      #label("SHIP TO")
      #v(5pt)
      #if data.at("shipping_name", default: none) not in (none, "") [
        #text(weight: "semibold")[#data.shipping_name]
        #v(4pt)
      ]
      #data.delivery_address
      #if data.at("shipping_gstin", default: none) not in (none, "") [
        #v(4pt)
        GSTIN #data.shipping_gstin
      ]
      #if data.at("delivery_state_code", default: none) not in (none, "") [
        #v(4pt)
        #label("State") #data.delivery_state_code
      ]
      #v(9pt)
    ]
    #label("PLACE OF SUPPLY")
    #v(6pt)
    #data.place_of_supply_display
    #v(8pt)
    #label("Reverse charge") No
    #if credit [
      #v(8pt)
      #label("Original invoice")
      #v(4pt)
      #data.original_invoice_number
      #if data.at("original_invoice_date", default: none) != none [
        #v(3pt)
        #data.original_invoice_date
      ]
    ]
  ],
)
#if data.at("subject", default: none) not in (none, "") [
  #v(11pt)
  #label("WORK") #h(7pt) #text(weight: "semibold")[#data.subject]
]
#v(12pt)

#table(
  columns: (1fr, 52pt, 31pt, 64pt, 35pt, 74pt),
  inset: (x: 5pt, y: 5pt),
  stroke: (top: none, left: none, right: none, bottom: 0.4pt + rule),
  align: (left, left, right, right, right, right),
  table.header(..("Item", "HSN/SAC", "Qty", "Rate", "GST", "Amount").map(s => text(size: 8pt, fill: muted)[#s])),
  ..data.lines.map(item => (
    [#item.description],
    text(size: 8pt)[#item.sac],
    [#item.quantity#if item.at("unit", default: none) not in (none, "") [
      #linebreak()
      #text(size: 7pt, fill: muted)[#item.unit]
    ]],
    [#item.rate_display],
    [#item.gst_rate%],
    [#item.taxable_display],
  )).flatten(),
)
#v(9pt)
#align(right, block(width: 68mm, breakable: false)[
  #grid(columns: (1fr, auto), align: (left, right), column-gutter: 12pt, row-gutter: 8pt,
    label("Taxable amount"), [#data.subtotal_display],
    ..data.tax_rows.map(row => (label(row.label), [#row.amount])).flatten(),
  )
  #v(7pt)
  #line(length: 100%, stroke: 0.7pt + rule)
  #v(7pt)
  #grid(columns: (1fr, auto), align: (left, right), column-gutter: 12pt,
    text(weight: "semibold")[#if credit { "Credit total" } else { "Total" }],
    text(size: 15pt, weight: "semibold")[#data.total_display],
  )
])

#v(12pt)
#grid(columns: (1fr, 75mm), gutter: 18pt,
  [
    #if data.at("total_in_words", default: none) not in (none, "") [
      #text(size: 8pt, fill: muted)[#data.total_in_words]
    ]
    #if data.at("notes", default: none) != none and data.notes != "" [
      #v(12pt)
      #label("NOTES")
      #v(5pt)
      #data.notes
    ]
    #if quotation [
      #v(14pt)
      #text(size: 8pt, fill: muted)[This quotation is not a tax invoice.]
    ]
  ],
  align(right, block(width: 75mm, breakable: false)[
    #label("For " + data.supplier.name)
    #if data.supplier.at("signature_file", default: none) != none [
      #v(5pt)
      #image(data.supplier.signature_file, width: 50mm, height: 12mm, fit: "contain")
    ] else [
      #v(20pt)
      #line(length: 50mm, stroke: 0.7pt + rule)
    ]
    #v(5pt)
    #label("Authorised signatory")
  ]),
)
