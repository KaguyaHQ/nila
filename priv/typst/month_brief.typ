// Month brief: reads in 90 seconds. Cover numbers, exceptions one line each,
// the finding, one evidence page. Depth lives in the Excel + scans it ships
// with; this document only has to survive a phone screen and a busy partner.

#import "_shared.typ": *

#let section(title) = {
  v(1.3em)
  text(font: sans, size: 10.5pt, weight: "semibold", fill: ink)[#title]
  v(0.3em)
  line(length: 100%, stroke: 0.7pt + rule)
  v(0.6em)
}

#let small-table(cols, header, rows) = table(
  columns: cols,
  inset: (x: 5pt, y: 4.5pt),
  stroke: none,
  align: horizon,
  table.header(..header.map(h => table.cell([#label-text(h)]))),
  table.hline(stroke: 0.7pt + rule),
  ..rows
    .enumerate()
    .map(((idx, cells)) => {
      let sep = if idx == 0 { () } else { (table.hline(stroke: 0.4pt + hair),) }
      sep + cells.map(c => text(size: 8pt)[#c])
    })
    .flatten(),
  table.hline(stroke: 0.7pt + rule),
)

#let main(data) = {
  show: document-frame.with(
    title: "GST Month Brief — " + data.meta.entity + " " + data.meta.period,
    author: "Nila",
    footer-note: data.meta.entity + " · " + data.meta.period + " · full register, scans, and portal files accompany this brief",
  )

  // ---- Page 1: the brief ----
  letterhead(
    (name: data.meta.entity, address: data.meta.address, gstin: data.meta.gstin),
    "GST Month Brief",
    data.meta.period,
    marking: "Purchase side · prepared for review",
  )

  let c = data.cover
  ref-strip((
    ("Invoices processed", str(c.invoice_count)),
    ("Matched to GSTR-2B", str(c.matched_count)),
    ("Need a decision", str(c.needs_human_count + c.not_in_2b_count + c.in_2b_only_count)),
    ("Taxable", c.taxable_total),
  ))

  v(1.2em)

  text(size: 9.5pt)[
    #str(c.invoice_count) purchase invoices for #data.meta.period, reconciled
    line-by-line against the GSTR-2B downloaded from the portal.
    #str(c.matched_count) match with no difference. Everything else is on the
    next page with a reason and a drafted next step — nothing was guessed.
    Every number traces to a scanned bill in the accompanying files.
  ]

  section("Worth your attention")

  text(size: 9.5pt)[
    #strong[The ITC claimed in the filed GSTR-3B (#data.itc.filed_3b) equals
    the GSTR-2B total exactly.] That claim includes
    #data.itc.in_2b_only_tax of GST on documents no bill was provided
    for — four Porter (Smartshift Logistics) credit notes — and
    #data.itc.awaiting_tax on invoices this pack routes to a human
    decision, including bills scanned twice. Whether each belongs in the
    claim is the reviewer's call; the trace for every line is attached.
  ]

  v(0.8em)

  let itc = data.itc
  grid(
    columns: (1fr, auto),
    row-gutter: 0.55em,
    text(size: 8.5pt, fill: muted)[GST on invoices matched to the portal],
    text(size: 8.5pt, weight: "medium")[#itc.matched_tax],
    text(size: 8.5pt, fill: muted)[GST awaiting a human decision],
    text(size: 8.5pt, weight: "medium")[#itc.awaiting_tax],
    text(size: 8.5pt, fill: muted)[GST with no bill provided],
    text(size: 8.5pt, weight: "medium")[#itc.in_2b_only_tax],
    text(size: 8.5pt, fill: muted)[Total per GSTR-2B],
    text(size: 8.5pt, weight: "medium")[#itc.total_2b_tax],
    text(size: 8.5pt, fill: muted)[Net ITC in the filed GSTR-3B],
    text(size: 8.5pt, weight: "medium")[#itc.filed_3b],
  )

  pagebreak()

  // ---- Page 2: exceptions, one line each ----
  section("Needs a decision — " + str(data.exceptions.len()) + " items")
  small-table(
    (auto, 1fr, auto, auto, auto),
    ("Inv No", "Vendor", "Amount", "Why it stopped", "Scan"),
    data.exceptions.map(e => (
      e.inum,
      e.vendor,
      e.amount,
      e.short_reason,
      e.pages,
    )),
  )
  v(0.5em)
  text(size: 8pt, fill: muted)[
    Drafted follow-ups (vendor chasers, client questions) for each item are in
    the accompanying register file, next-action column.
  ]

  // ---- Page 3: catches, one line each ----
  section("Caught by the checks — " + str(data.catches.len()) + " items")
  small-table(
    (auto, auto, 1fr, auto),
    ("", "Inv No", "What was caught", "Scan"),
    data.catches.map(f => (
      upper(f.severity),
      f.inum,
      f.short_reason,
      f.pages,
    )),
  )
  v(0.5em)
  text(size: 8pt, fill: muted)[
    None of these is a verdict — each names its evidence and the decision
    stays with the reviewer. #str(data.cover.correction_count) extraction
    values were corrected against the paper after reconciliation disagreed;
    the register carries the corrected values.
  ]

  // ---- Evidence sample: one page ----
  if data.sample_evidence != none {
    pagebreak()
    grid(
      columns: (1fr, auto),
      align: (left + top, right + top),
      text(font: sans, size: 10pt, weight: "semibold")[
        Evidence sample — #data.sample_evidence.inum · #data.sample_evidence.vendor
      ],
      text(size: 8pt, fill: muted)[#data.sample_evidence.note],
    )
    v(0.5em)
    line(length: 100%, stroke: 0.5pt + hair)
    v(0.6em)
    block(height: 1fr, width: 100%)[
      #align(center + top)[#image(data.sample_evidence.image, fit: "contain", width: 100%, height: 100%)]
    ]
  }
}
