# Sales preparation

Nila prepares the junior accountant's work: read the documents, resolve exceptions,
and produce traceable Excel workings and GSTR-1 drafts. The firm's senior and
manager can review those outputs in their existing tools. Sales has no approval
step in Nila.

## Where code belongs

- `../extraction/sales/normalizer.ex` converts extraction artifacts into invoice
  facts. Extraction schema aliases and raw evidence handling belong there.
- `invoice.ex` and `invoice/` own invoice facts, corrections, exclusions, and
  shared invoice checks. Corrections preserve the original extraction.
- `source_packet.ex` prepares effective source invoices and common checks before
  choosing an output. Both GSTR-1 and Tally consume it.
- `gstr1.ex` owns return tables, source contributions, and shared tax/HSN arithmetic.
  `gstr1/documents.ex` owns number-series controls and documents-issued counts;
  `gstr1/readiness.ex` checks output support and the selected period.
  `gstr1/packet.ex` assembles the output checks.
- `workings.ex` applies month decisions and derives the current working draft;
  `workings/xlsx.ex` writes the Excel artifact.
- `review.ex` and `review/` persist exception decisions and explain source facts,
  return contributions, and arithmetic controls. `review/correction_policy.ex`
  connects confidence and findings to fields that can be corrected; `Invoice`
  owns what each correction changes.
- `tally/` owns Tally preparation, register input, and posting edits. Tally ledger
  requirements must not become requirements for producing GST workings.
- `batch.ex`, `imports.ex`, `month.ex`, and `months.ex` own intake grouping and
  month persistence. `output_capabilities.ex` and `output_issues.ex` describe
  shared output support boundaries.

## Rules to preserve

Use `Invoice.apply_correction/3` for correction semantics. Persist source edits
through `Invoice.Corrections` and exclusions through `Invoice.Removals`; batch
references record where an edit happened, while source IDs identify the invoice.
Source edits invalidate the affected month review, but cannot alter filed months.

`Gstr1.project/2` produces both the portal return and the contribution of each
included source. Per-invoice review values must use that projection (or full
workings), rather than reconstructing amounts from the return or the invoice.
An absent contribution is unknown, not zero.

Legacy approval records remain only where historical filing and purchase-side
code need them. They do not freeze an unfiled sales month. Existing sent Tally
jobs retain their identity and protection against duplicate posting.

When sales inputs change, an unfiled 3B approval based on the previous working is
invalidated through the existing filing context. This never blocks sales edits
or rewrites an actually filed 3B.
