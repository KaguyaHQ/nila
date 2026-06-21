# Discovery

Evergreen knowledge about the customer, their workflows, the domain, and
the real artifacts (emails, sheets, replies) that the product has to
handle. Unlike plans, discovery does not expire when a feature ships.
Keep it.

## What lives here

- Customer workflow studies — how the user actually works today, what
  they keep in their head, where the friction lives.
- Real-world artifact samples — anonymized email threads, sheet exports,
  reply patterns, OEM-specific quirks.
- Domain knowledge that isn't already in `glossary.md` because it needs
  more than two lines (e.g. why a Siemens GRN chain is a multi-party
  approval but a Philips SDC is single-approver).
- Open questions surfaced during discovery that no one has answered yet.

What does **not** live here: implementation plans (that's `docs/.plans/`),
product overview (that's `docs/prd.md`), or system decisions (that's
`docs/decisions.md`). Discovery is the *input* to plans; the plan should
cite which discovery findings drive each decision.

## How to add to it

- One file per study or domain area. Long is fine; discovery is meant to
  be deep.
- Keep raw quotes, real numbers, real artifact samples where possible.
  Discovery loses value when summarized too early.
- Anonymize names and emails before committing if the source is sensitive.
- When a plan cites discovery, link the specific section (e.g.
  `customer-workflows.md §8.4`), not the whole file.

## Index

- [`customer-workflows.md`](./customer-workflows.md) — the family's live
  Caltech / Breezetech receivables workflow across Siemens, Philips,
  Varian, and Elekta. Real emails, real reply patterns, OEM-specific
  approval shapes, the spreadsheet that is currently the data model, and
  the open questions that shaped the SDC approval chase plan.
- [`quotation-workflow.md`](./quotation-workflow.md) — the *quoting* front
  end: a 461-tab, 6-year quote workbook (₹9.93cr, 454 quotes across
  Philips/Siemens/GE). The real quote shape, the HVAC/CAMC catalog, the
  defect→constraint table, and how a `Quote` maps onto the existing
  `Invoice`/`LineItem`/`Customer`/`Entity` schema.
