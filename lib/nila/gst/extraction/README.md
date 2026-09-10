# GST extraction

Extraction reads source documents and returns structured artifacts with evidence.
It does not decide filing readiness, apply human decisions, or build returns.

## Where code belongs

- `sales.ex` and `purchase.ex` define extractor contracts. Their `extractor.ex`
  implementations select the document kind and call the shared `pipeline.ex`.
- `pipeline.ex` runs discovery and invoice reading, contains failed segments,
  and assembles artifacts and per-call audits.
- `source_pages.ex` prepares PDF/image pages, enforces size limits, and selects text
  or image input. `evidence.ex` renders pages; `native_text.ex` reads PDF text.
- `discovery/sales_pages.ex` and `discovery/purchase_pages.ex` own each packet's
  page-label prompt, schema, and grouping rules.
- `invoice_request.ex` combines `invoice_prompt.ex` and `invoice_schema.ex` into
  the provider request. Prompt and schema changes are extraction behavior changes.
- `invoice_repairs.ex` repairs model candidates and records what changed and why.
  `invoice_verification.ex` checks captured evidence and arithmetic without changing it.
- `providers/` owns HTTP requests, retries, response decoding, and the Finch pool.
- `sales/normalizer.ex` is the adapter from extracted artifacts to sales invoices.
  It reads artifact envelopes and calls `Sales.Invoice` for shared invoice rules.
  Normalizing an artifact does not apply a human review decision.

## Shared facts and downstream ownership

`Nila.Gst.LineAmounts` interprets printed and corrected line amounts.
`Nila.Gst.TaxComponents` interprets printed tax components and totals. Both live
outside extraction because extraction, review, and return code consume them.
Extraction-specific repairs remain in `InvoiceRepairs`.

`Sales.Invoice` owns normalized sales facts and correction semantics. Sales
modules must not depend on extraction modules. The normalizer is the one adapter
that deliberately knows both the extraction format and the sales invoice.

Extraction verification and sales filing validation answer different questions.
Keep their evidence requirements and arithmetic tolerances separate. Preserve
raw evidence, repair records, missing-versus-zero values, source pages, existing
artifact keys, and audit stage names during organizational changes.
