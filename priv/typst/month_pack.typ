// Month pack: the closing note a good junior hands the partner. Boring on
// purpose — dense tables, no decoration. Every value arrives pre-formatted.

#import "_shared.typ": *

#let section(title) = {
  v(1.6em)
  text(font: sans, size: 11pt, weight: "semibold", fill: ink)[#title]
  v(0.35em)
  line(length: 100%, stroke: 0.7pt + rule)
  v(0.8em)
}

#let kv(k, v) = grid(
  columns: (auto, 1fr),
  column-gutter: 1.2em,
  text(size: 8.5pt, fill: muted)[#k],
  text(size: 8.5pt, weight: "medium")[#v],
)

#let small-table(cols, header, rows) = table(
  columns: cols,
  inset: (x: 5pt, y: 5pt),
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
    title: "GST Month Pack — " + data.meta.entity + " " + data.meta.period,
    author: "Nila",
    footer-note: data.meta.entity + " · " + data.meta.period + " · prepared " + data.meta.prepared_on,
  )

  // ---- Cover / status ----
  letterhead(
    (name: data.meta.entity, address: data.meta.address, gstin: data.meta.gstin),
    "GST Month Pack",
    data.meta.period,
    marking: "Purchase side · prepared for review",
  )

  let c = data.cover
  ref-strip((
    ("Invoices processed", str(c.invoice_count)),
    ("Matched to GSTR-2B", str(c.matched_count)),
    ("Routed to human", str(c.needs_human_count)),
    ("Catches flagged", str(c.flag_count)),
  ))

  v(1.4em)

  text(size: 9.5pt)[
    This pack covers every purchase document received for #data.meta.period:
    #str(c.invoice_count) invoices totalling #c.taxable_total taxable.
    #str(c.matched_count) reconciled against the GSTR-2B downloaded from the
    portal with no difference. #str(c.needs_human_count) need a human decision
    (each with the reason and a drafted next step), #str(c.not_in_2b_count)
    are missing from the vendor's filing, and #str(c.in_2b_only_count) appear
    in GSTR-2B but not in the documents provided. Every invoice in the
    register names the scanned page it came from; the accompanying Excel
    opens that scan from each line, and every exception and catch in this
    pack reproduces its source page in the evidence section at the back.
  ]

  section("Reconciliation against GSTR-2B")
  small-table(
    (auto, 1fr, auto, auto, auto),
    ("Inv No", "Vendor", "Amount", "Status", "Evidence"),
    data.exceptions.map(e => (e.inum, e.vendor, e.amount, e.bucket, e.pages)),
  )
  v(0.6em)
  text(size: 8pt, fill: muted)[
    Only exceptions are listed; the #str(c.matched_count) matched invoices
    appear in the full register (last section) and in the accompanying Excel
    file. For each exception the drafted follow-up is on the next page.
  ]

  pagebreak()

  // ---- Exceptions with next actions ----
  section("Exceptions — what happens next")
  for e in data.exceptions {
    if e.next_action != none or e.note != none {
      block(breakable: false)[
        #text(size: 8.5pt, weight: "semibold")[#e.inum — #e.vendor (#e.amount)]
        #v(0.2em)
        #if e.note != none [
          #text(size: 8pt, fill: muted)[#e.note] \
        ]
        #if e.next_action != none [
          #text(size: 8pt)[→ #e.next_action]
        ]
        #v(0.7em)
      ]
    }
  }

  pagebreak()

  // ---- Catches ----
  section("What the checks caught")
  text(size: 8.5pt, fill: muted)[
    Each catch names its evidence and, where relevant, the statutory hook.
    None of these is a verdict — the decision stays with the reviewer.
  ]
  v(0.8em)
  for f in data.catches {
    block(breakable: false)[
      #grid(
        columns: (auto, 1fr),
        column-gutter: 0.8em,
        text(size: 7.5pt, weight: "semibold", fill: if f.severity == "error" { ink } else { muted })[
          #upper(f.severity)
        ],
        [
          #text(size: 8.5pt, weight: "semibold")[#f.inum — #f.vendor #if f.section != none [ · #f.section]]
          #v(0.15em)
          #text(size: 8pt)[#f.reason]
          #text(size: 7.5pt, fill: faint)[ (#f.pages)]
        ],
      )
      #v(0.65em)
    ]
  }

  pagebreak()

  // ---- Corrections trace ----
  section("Extraction corrections — checked against the paper")
  text(size: 8.5pt, fill: muted)[
    Every value the system read is reconciled against GSTR-2B; where they
    disagreed, the scanned page was re-read by a human. In all
    #str(data.cover.correction_count) cases below the paper agreed with the
    portal and the extraction was corrected. The register carries the
    corrected values.
  ]
  v(0.8em)
  small-table(
    (auto, auto, 1fr),
    ("Inv No", "Field", "What the paper showed"),
    data.corrections.map(x => (x.inum, x.field, x.why)),
  )

  // ---- Confession sheet ----
  section("What we could not decide")
  text(size: 8.5pt, fill: muted)[
    These items were routed to a human instead of guessed. Each names why the
    system stopped.
  ]
  v(0.8em)
  small-table(
    (auto, 1fr, 2fr, auto),
    ("Inv No", "Vendor", "Why it stopped", "Evidence"),
    data.confession.map(x => (x.inum, x.vendor, x.why, x.pages)),
  )

  pagebreak()

  // ---- ITC position ----
  section("Input tax credit position")
  kv("GST on invoices matched to GSTR-2B", data.itc.matched_tax)
  v(0.3em)
  kv("GST on invoices not yet matched", data.itc.unmatched_tax)
  v(0.8em)
  text(size: 8.5pt, fill: muted)[
    No eligibility figure is computed: the items below carry statutory
    questions only a reviewer can settle. Each is flagged with its evidence;
    the arithmetic is left to the professional.
  ]
  v(0.8em)
  small-table(
    (auto, 1fr, auto, auto),
    ("Inv No", "Vendor", "GST", "Question"),
    data.itc.flagged.map(x => (x.inum, x.vendor, x.tax, x.code)),
  )
  if data.itc.filed_3b != none {
    v(0.8em)
    kv("ITC claimed in filed GSTR-3B", data.itc.filed_3b)
  }

  pagebreak()

  // ---- Full register ----
  section("Purchase register — " + data.meta.period)
  small-table(
    (auto, auto, 1fr, auto, auto, auto, auto),
    ("Inv No", "Date", "Vendor", "Taxable", "GST", "2B", "Pages"),
    data.register.map(r => (r.inum, r.date, r.vendor, r.taxable, r.tax, r.bucket, r.pages)),
  )

  // ---- Evidence appendix ----
  // One page per scan: slim header band, scan fills the remainder of the
  // same page (fit: contain), so the flagged line and its paper never split.
  for item in data.appendix {
    for (idx, img) in item.images.enumerate() {
      pagebreak()
      grid(
        columns: (1fr, auto),
        align: (left + top, right + top),
        [
          #text(font: sans, size: 10pt, weight: "semibold")[Evidence — #item.inum · #item.vendor]
          #if item.images.len() > 1 [
            #text(size: 8pt, fill: faint)[ (sheet #str(idx + 1) of #str(item.images.len()))]
          ]
        ],
        [
          #text(size: 8pt, fill: muted)[#item.bucket]
          #if item.flags != none [
            #linebreak()
            #text(size: 7.5pt, fill: faint)[#item.flags]
          ]
        ],
      )
      v(0.5em)
      line(length: 100%, stroke: 0.5pt + hair)
      v(0.6em)
      block(height: 1fr, width: 100%)[
        #align(center + top)[#image(img, fit: "contain", width: 100%, height: 100%)]
      ]
    }
  }
}
