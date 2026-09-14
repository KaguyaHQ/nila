# GST extraction

Extraction reads source documents and returns structured artifacts with evidence.
It does not decide filing readiness, apply human decisions, or build returns.

## Where code belongs

- `sales.ex` and `purchase.ex` define extractor contracts. Their `extractor.ex`
  implementations select the document kind and call the shared `pipeline.ex`.
- `pipeline.ex` runs discovery and invoice reading, contains failed segments,
  and assembles artifacts and per-call audits.
- `source_pages.ex` prepares PDF/image pages, enforces size limits, and selects text
  or image input. `evidence.ex` renders pages; `native_text.ex` reads Poppler text.
  `native_tables.ex` runs `priv/python/invoice_tables.py` for MuPDF table cells.
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

For sales uploads, the worker saves discovery through `on_segments`, then saves each
verified artifact through `on_invoice` before publishing its progress. Saved segment
order keeps invoice IDs stable. A retry reuses that discovery and completed artifacts.
`Sales.Processing` keeps this checkpoint in the upload's existing metadata; unfinished
invoices are available to review but stay out of stored month totals and exports.

For an internal reread of a completed sales upload, use
`Nila.Gst.Intake.Reextract.run(org_id, dump_id)` from the application console.
It calls the current configured extractor without reusing completed artifacts.
The existing upload is replaced only after a complete read and a second check for
human changes; the month is rebuilt in the same database transaction. Original
files, old page images and extraction attempts are retained. It refuses reviewed
or filed months, source corrections/removals, any decisions in the affected month,
and sources used in another month. Failures keep the old result. This is an internal
operation, not a UI retry; do not reset a completed upload's status to force a retry.

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

## Sales route

Development and production select `input: :native, contract: :semantic`: MuPDF tables for eligible
digital pages, images for scans and failed conversion. A scanned continuation sends
the whole invoice through images. No OCR or learned Layout model runs in this route.
Layout is deliberately disabled. On 14 September 2026, PyMuPDF/Layout 1.28.2
with `use_layout=True` detached decimal points on Simple Systems invoice
`I-SS-2627-53` (for example, `4810.50` became `481050` followed by `.` on another
line). PyMuPDF4LLM 1.28.2 with Layout enabled also split its GSTIN across columns
and damaged decimals; a direct rerun reproduced the same Markdown. Plain MuPDF
with Layout off preserved those values. This is a verified case-specific failure,
not a claim that Layout or 4LLM always performs worse. Before enabling either,
recheck this invoice and the regression corpus. Saved comparisons are under
`tmp/2026-09-14/invoice-extraction/local-native-check/`.

`NILA_INVOICE_PYTHON` can select an interpreter with PyMuPDF 1.28.2; this Windows
workspace defaults to the existing evaluation virtual environment. Production installs
the pinned `priv/python/requirements.txt` into its Python 3.11 runtime. Missing tooling
falls back to images and records a reason in the extraction audit.

The semantic contract asks for `amount_before_gst` and `amount_including_gst`.
The decoder maps them to existing accounting fields before repairs and verification.
Stored invoices are unchanged. Gross amounts with only a printed tax rate and no
tax amount currently remain unresolved under this contract and require review.
Purchases retain their existing defaults. New settings apply on
server restart; old saved answers require explicit re-extraction.
