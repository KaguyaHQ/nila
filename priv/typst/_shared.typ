// Shared layout primitives for Nila documents (quote, invoice). Identical skin,
// different organs: the templates compose these and add their own sections.
//
// Type is the brand pairing (DM Sans + Newsreader serif for display moments),
// vendored in priv/typst/fonts so the render is identical on any machine.
// Pure layout — every value arrives pre-formatted from the Elixir Pdf modules.

#let ink = oklch(28%, 0.055, 233deg)
#let muted = oklch(46%, 0.03, 233deg)
#let faint = oklch(60%, 0.02, 233deg)
#let hair = oklch(89%, 0.012, 233deg)
#let rule = oklch(74%, 0.025, 233deg)

#let sans = ("DM Sans",)
#let serif = ("Newsreader",)

// Hand-entry blanks already arrive as "-"; nulls (dates, gstin) arrive as none.
#let opt(v) = if v == none { "-" } else { v }

#let label-text(s) = text(
  font: sans,
  size: 6.8pt,
  fill: faint,
  weight: "semibold",
  tracking: 0.09em,
)[#upper(s)]

#let display(s, size: 17pt, fill: ink, weight: "medium") = text(
  font: serif,
  size: size,
  fill: fill,
  weight: weight,
)[#s]

// Page frame: A4, brand text defaults, slim running footer with page numbers.
// Use as `show: document-frame.with(title: …, author: …, footer-note: …)`.
#let document-frame(title: "", author: "", footer-note: "", body) = {
  set document(title: title, author: author)
  set page(
    "a4",
    margin: (x: 18mm, top: 16mm, bottom: 18mm),
    footer: context {
      set text(font: sans, size: 7pt, fill: faint)
      grid(
        columns: (1fr, auto),
        align: (left, right),
        footer-note,
        [Page #counter(page).display() of #counter(page).final().first()],
      )
    },
  )
  set text(font: sans, size: 9pt, fill: ink)
  set par(leading: 0.55em)
  body
}

// Letterhead band: serif supplier name left; document kind, number, and an
// optional copy marking ("Original for Recipient") right. Closes with a rule.
#let letterhead(supplier, kind, label, marking: none) = {
  grid(
    columns: (1fr, auto),
    align: (left + top, right + top),
    gutter: 2em,
    [
      #display(supplier.name, size: 20pt)
      #v(0.55em)
      #if supplier.address != "" [
        #text(size: 8pt, fill: muted)[#supplier.address] \
      ]
      #if supplier.gstin != none [
        #text(size: 8pt, fill: muted, weight: "medium")[GSTIN #supplier.gstin]
      ]
    ],
    [
      #label-text(kind)
      #v(0.45em)
      #display(label, size: 17pt, weight: "regular")
      #if marking != none [
        #v(0.35em)
        #text(size: 7.5pt, fill: faint)[#marking]
      ]
    ],
  )

  v(1.1em)
  line(length: 100%, stroke: 0.7pt + rule)
  v(1.2em)
}

// Horizontal strip of label-over-value facts. `pairs` is ((key, value), …).
#let ref-strip(pairs) = grid(
  columns: pairs.len(),
  column-gutter: 3em,
  ..pairs.map(((k, value)) => [
    #label-text(k)
    #v(0.4em)
    #text(size: 9.5pt, weight: "medium")[#opt(value)]
  ])
)

#let party(title, name, address, gstin: none, state: none) = [
  #label-text(title)
  #v(0.45em)
  #text(size: 9.5pt, weight: "medium")[#name]
  #if address != none and address != "-" [
    \ #text(size: 8.5pt, fill: muted)[#address]
  ]
  #if gstin != none [
    \ #text(size: 8.5pt, fill: muted, weight: "medium")[GSTIN #gstin]
  ]
  #if state != none [ \ #text(size: 8.5pt, fill: muted)[#state] ]
]

#let two-col(left-cell, right-cell) = grid(
  columns: (1fr, 1fr),
  gutter: 2.5em,
  align: (left + top, left + top),
  left-cell, right-cell,
)

// Line-item table: # / Description / HSN / Qty / Rate / GST% / Amount (taxable).
// Tax amounts live in the totals band, not per line.
#let items-table(lines, empty-text) = {
  let header-cell(s, align: left) = table.cell(align: align + horizon)[#label-text(s)]
  let num(s) = align(right)[#s]

  table(
    columns: (auto, 1fr, auto, auto, auto, auto, auto),
    inset: (x: 6pt, y: 8pt),
    stroke: none,
    align: horizon,
    table.header(
      header-cell("#"),
      header-cell("Description"),
      header-cell("HSN/SAC"),
      header-cell("Qty", align: right),
      header-cell("Rate", align: right),
      header-cell("GST", align: right),
      header-cell("Amount", align: right),
    ),
    table.hline(stroke: 0.7pt + rule),
    ..if lines.len() == 0 {
      (table.cell(colspan: 7, align: center)[
        #v(1em) #text(fill: muted)[#empty-text] #v(1em)
      ],)
    } else {
      lines
        .enumerate()
        .map(((idx, line)) => {
          let sep = if idx == 0 { () } else { (table.hline(stroke: 0.5pt + hair),) }
          sep + (
            text(size: 8.5pt, fill: faint)[#line.position],
            text(weight: "medium")[#line.description],
            text(size: 8.5pt, fill: muted)[#line.hsn],
            num(text(fill: muted)[#line.qty]),
            num(text(fill: muted)[#line.rate]),
            num(text(size: 8.5pt, fill: muted)[#line.gst_rate]),
            num(text(weight: "medium")[#line.taxable]),
          )
        })
        .flatten()
    },
    table.hline(stroke: 0.7pt + rule),
  )
}

// Amount-in-words (left, serif italic) beside the totals column (right):
// subtotal and tax rows, a hairline, then the serif total.
// `rows` is ((label, value), …); `in-words: none` collapses the left cell.
#let totals-band(rows, total-value, in-words: none, total-label: "Total") = grid(
  columns: (1fr, 66mm),
  gutter: 3em,
  align: (left + bottom, right + top),
  if in-words != none {
    [
      #label-text("Amount in words")
      #v(0.45em)
      #text(font: serif, size: 9.5pt, fill: muted, style: "italic")[#in-words]
    ]
  },
  [
    #grid(
      columns: (1fr, auto),
      row-gutter: 0.7em,
      align: (left, right),
      ..rows.map(((k, value)) => (text(fill: muted)[#k], text()[#value])).flatten(),
    )
    #v(0.7em)
    #line(length: 100%, stroke: 0.5pt + hair)
    #v(0.7em)
    #grid(
      columns: (1fr, auto),
      align: (left + horizon, right + horizon),
      text(size: 9.5pt, weight: "medium")[#total-label],
      display(total-value, size: 16pt),
    )
  ],
)

#let signature(for-name) = align(right)[
  #text(size: 8.5pt, fill: muted)[For #for-name]
  #v(2.8em)
  #line(length: 44mm, stroke: 0.5pt + rule)
  #v(0.25em)
  #text(size: 8pt, fill: faint)[Authorised Signatory]
]
