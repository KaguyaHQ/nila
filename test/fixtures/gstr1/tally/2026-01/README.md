# Native Tally sales workings fixture

Captured on 2026-09-05 from the disposable local company
`CALTECH GST PRACTICE - DEC 2025` (GUID
`fb7551b0-e015-4489-bb16-135a58fa492d`, GSTIN `33BPBPK1081A1ZO`).
January 2026 was empty before fixture creation. The eight vouchers below remain
in Tally and were read back through NilaConnector.Diagnostics after export.

The private corpus packet `tally-caltech-2026-01-sales` concatenates eight native
Tally PDF exports, without changing their page content. Its bytes live in the
`nila-eval-corpus` R2 bucket at `tally/caltech/2026-01/sales-b2b-b2cs-b2cl-registered-notes.pdf`, with a local
source copy at `D:/eval-corpus/tally/caltech/2026-01/sales-b2b-b2cs-b2cl-registered-notes.pdf`; no PDF is stored
in Git. The registry is `eval/corpus.json`; the benchmark fetches and verifies
the packet through `Nila.EvalCorpus`. This synthetic packet is separate from
the real client packet `caltech-2026-01-sales`.
All eight pages were rendered and visually checked.
`native-gstr1.json` is Tally's untouched **Export Offline / JSON** GSTR-1 output,
not a Nila-derived expectation. No return was uploaded or filed on the GST portal.
The native report included all eight vouchers, with no uncertain transactions.

| Page | Document | Master ID | Supply | Invoice/note value | Native table |
| --- | --- | --- | --- | ---: | --- |
| 1 | NW-001 | 6 | Unregistered, Tamil Nadu | 11,800 | B2CS |
| 2 | NW-002 | 7 | Unregistered, Karnataka | 90,000 | B2CS |
| 3 | NW-003 | 8 | Unregistered, Karnataka | 100,000 | B2CS |
| 4 | NW-004 | 9 | Unregistered, Karnataka | 110,000 | B2CL |
| 5 | NW-005 | 10 | Unregistered, Tamil Nadu | 118,000 | B2CS |
| 6 | NW-006 | 11 | Registered, Andhra Pradesh | 23,600 | B2B |
| 7 | NW-CN-001 | 12 | Registered credit note | 2,360 | CDNR, C |
| 8 | NW-DN-001 | 13 | Registered debit note | 1,180 | CDNR, D |

All documents are dated 15-Jan-2026, use service SAC 998719 and 18% GST.
Both notes reference NW-006. Native debit-note reason: Correction in Invoice.
The native credit-note PDF's heading is "Tax Invoice", but its number field
says "Credit Note No."; the extractor correctly recognizes it as a credit note.

## Extraction and review

`extraction.json` is the reduced offline regression input from one production
sales vision run. It retains `unaccounted_pages` and each page's `data`,
`document`, `page`, `source_pages`, `source_attribution`, `confidence` and
`verification`. These values are copied unchanged; no reviewer corrections
are baked into the extraction. The full and reduced records were checked to
produce identical normalized invoices.

The full extraction record, including raw model responses, audit,
segmentation and usage metadata, lives in the private eval corpus. Its bucket,
object key, SHA-256 and size are recorded in `manifest.json` under
`full_extraction`; the local archive uses the same key under `D:/eval-corpus/`.
To regenerate the reduced input, retain only the fields listed above from that
archived record. Provider/model and source hashes remain in `manifest.json`.

Git keeps this small regression input, native expected return, explicit review
corrections and provenance. Full extraction records and historical runs belong
in the private corpus; local benchmark outputs go under ignored `tmp/`.
Tests replay the reduced input without network access or model calls.
This tests extraction artifacts through the real normalizer and review engine;
it does not exercise LiveView uploads, job persistence or GST portal acceptance.

The run exposed a date-parser defect: native `15-Jan-26` was marked unreadable.
The shared parser now accepts English three-letter month names with two- or
four-digit years, removing all eight false date-review questions.

The latest run retains five place-of-supply questions. B2C PDFs print buyer/
consignee state but no explicit place of supply; Nila asks for review rather
than treating an address as supply evidence. The improved extraction prompt
now reads the debit-note SAC embedded in its description. The original missed
SAC run remains archived under `previous_extraction` in the manifest.

`review.json` contains only the five explicit place-of-supply corrections,
confirmed from fixture setup/native Tally. These are applied through `Workings.materialize/3` with
the same flagged-field restrictions as production. They are not model output
and were not submitted as approvals to a persisted Nila month.

After review, there are no remaining workings issues or silent corrections.
Every compared financial/classification/date/document-series field agrees with
native Tally. Net taxable value is 383,237.29; IGST 49,182.71; CGST and SGST
9,900 each. Registered HSN value is 20,000 - 2,000 + 1,000 = 19,000.

The full comparison score is **98.02**, not 100: the two B2C HSN text fields
`desc` and `user_desc` differ. Nila uses the printed service name; Tally exports
an empty `desc` and its master description as `user_desc`. That master description
is not printed on the PDFs. Tests keep precisely those two mismatches visible
and permit no other mismatch; the native expectation is never rewritten.

## Reproduce

```powershell
mix test test/nila/gst/sales/tally_workings_test.exs

# Replays the cached extraction, writing results only under tmp:
New-Item -ItemType Directory -Force tmp/tally-replay
Copy-Item test/fixtures/gstr1/tally/2026-01/extraction.json tmp/tally-replay/
mix run --no-start eval/benchmarks/tally_sales_workings.exs score test/fixtures/gstr1/tally/2026-01 tmp/tally-replay
mix run --no-start eval/benchmarks/tally_sales_workings.exs score test/fixtures/gstr1/tally/2026-01 tmp/tally-replay test/fixtures/gstr1/tally/2026-01/review.json

# Optional live model rerun using configured extraction credentials:
mix run --no-start eval/benchmarks/tally_sales_workings.exs extract test/fixtures/gstr1/tally/2026-01
```

The benchmark never connects to Tally. Fixture creation used disposable Tally
data and native exports; no outbound Nila-to-Tally integration was added.

## Coverage boundary

This packet verifies service invoices, local B2C above/below the interstate
threshold, interstate B2C below/at/above it, a registered invoice and registered
credit/debit notes. It does not establish goods, mixed-rate, multi-page,
historical-threshold or other sellers' layout coverage.

The adjacent February fixture covers unregistered notes and March covers
Table 8 nil-rated, exempt and non-GST supplies. Exports, SEZ, outward reverse
charge, amendments and cancelled-document filing remain outside this work.
