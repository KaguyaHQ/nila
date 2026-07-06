# GSTR-1 reproduction eval — May 2026 Breeze Tech

Goal (today): prove the dump → draft → review loop on a real filed return.
Input: `breeze_may_sales.pdf` (15-page CamScanner scan bundle, one invoice per page,
"Original For Recipient" copies — the exact packet sent to the auditor).
Ground truth: `returns_06072026_R1_33AEWPH4158J1Z3_offline_others_0.zip` (GST portal
download of the filed GSTR-1, period 052026, filed 10-06-2026).

Claim being proven: Nila extracts the scanned bundle, derives a portal-shaped GSTR-1
JSON, flags exceptions, and reaches the filed return exactly after human review touches
only flagged fields. This is a **reproduction** claim on one bundle, not an accuracy
benchmark. Holdout months come later.

Important framing: the filed JSON is the **auditor's manual transcription of the same
scans**. On any mismatch, the scanned page adjudicates — possible outcomes are
Nila-wrong, auditor-wrong, or both. Never auto-score a mismatch as a Nila failure
without eyeballing the page. A "Nila right, filed return wrong" case is a headline
finding, not a bug.

## Ground truth facts (already verified against the zip)

- Top: gstin `33AEWPH4158J1Z3`, fp `052026`, monthly, fil_dt `10-06-2026`.
- `b2b`: 2 CTINs — `33AABCP9487A1ZG` (14 invoices), `33AAVCS8021P1ZM` (1 invoice). 15 total.
- Every filed invoice has exactly one item line, `rt: 18`, intra-state (camt/samt, iamt 0), `pos: "33"`, `rchrg: "N"`, `inv_typ: "R"`.
- `hsn.hsn_b2b`: 3 rows — `2903`, `8415`, `9987` (services, ₹25.04L ≈ 98% of total). All `qty: 0`, uqc `OTH`/`NA`. HSN txval total 2,563,773.54 == b2b txval total exactly.
- `doc_issue`: one series `20/2026-27` → `37/2026-27`, totnum 18, cancel 3, net_issue 15.
- Page 1 (invoice 20/2026-27) verified against the scan: 4 printed line items collapse
  into 1 filed rate bucket (55,552 + 4,500 + 1,500 + 3,000 = 64,552 = filed txval;
  tax 5,809.68 ✓). Printed HSN/SAC codes are 6–8 digit (`8415900`, `29037100`, `998717`);
  filed HSN summary uses 4-digit.
- **Known poison on page 1**: the printed TOTAL "Value" cell says 2,75,000.00 but line
  items sum to 64,552. Grand total 76,171.36 is correct. A naive extractor that trusts
  the totals row fails here; Nila must reconcile line sums vs printed totals and raise
  an issue on mismatch. This exact page is the canary.

## Deliverables (all scripts, nothing in lib/ today)

1. `scripts/extract_sales.exs` — extraction
2. Validation layer (module inside the eval script or `scripts/` helper)
3. `scripts/eval_gstr1.exs` — derive + diff + scores
4. Corrections patch file → review-final score
5. (only if time) one frozen holdout month

### 1. Extraction — `scripts/extract_sales.exs`

Use the existing LlamaExtract v2 plumbing as reference:
`lib/nila/documents/extractor/llama_extract.ex` (upload → submit → poll → map). The PO
schema and `map_result` there are from the pre-pivot ops thesis — do NOT reuse the PO
schema; write a sales-invoice `data_schema`. Config/env already wired
(`LLAMA_CLOUD_API_KEY`, see `config/runtime.exs`).

- Upload `breeze_may_sales.pdf` once; submit with `extraction_target: "per_page"`
  (bundle is strictly one invoice per page). If per_page misbehaves, fallback: split
  into 15 single-page PDFs and run per_doc each — do not burn time debugging.
- Keep `confidence_scores: true`, `cite_sources: true`, tier `agentic`.
- Invoice schema fields (adapt descriptions from the PO schema's style):
  - invoice_number (e.g. `20/2026-27` — keep the `/2026-27` suffix verbatim)
  - invoice_date (printed as `DD.MM.YYYY`)
  - seller name/gstin, buyer name/gstin (GSTIN: 15 chars, describe format)
  - line_items[]: description, hsn_sac (6–8 digits as printed), quantity, uom,
    unit_price, taxable value, cgst/sgst/igst rate + amount
  - printed_total_taxable, printed_total_tax, printed_grand_total — extracted **only as
    reconciliation checks**, never as truth. Schema descriptions must say: line items
    are authoritative; printed totals may be wrong.
- Write raw per-page artifacts to `tmp/eval/2026-05-breeze/pages/*.json` (include the
  per-field confidence metadata, not just values).

### 2. Deterministic validation layer (runs on every extracted invoice)

Independent of model confidence — confidence catches "unsure", this catches
"confidently wrong". Each failure → an issue tagged with invoice + field. ~100 lines
pure Elixir.

- Arithmetic: per line, txval × rate ≈ cgst+sgst (or igst); lines sum → invoice
  taxable; taxable + tax ≈ grand total. Tolerance ±0.5 for rounding. Catches the
  page-1 poison total.
- GSTIN checksum: 15th char is the mod-36 check digit over the first 14
  (chars 0-9A-Z valued 0–35, weights alternate 1,2 per position, product split as
  quotient+remainder, sum, check = (36 − sum mod 36) mod 36). Flags OCR-garbled GSTINs.
- Consistency: buyer GSTIN state code (first 2 digits) vs pos vs tax split — same
  state ⇒ CGST/SGST, different ⇒ IGST.
- Sequence: sort extracted invoice numbers, infer series range, report gaps as
  "missing/cancelled inferred from sequence — confirm cancellation records".
  Expected here: 3 gaps in 20–37.

### 3. Derivation + diff — `scripts/eval_gstr1.exs`

Derive a portal-shaped GSTR-1 JSON from the 15 artifacts (this output file IS a
deliverable — "the file an auditor uploads"), then diff against the filed JSON.

Derivation:
- `b2b`: group by buyer GSTIN → ctin blocks; per invoice, bucket line items by rate
  (all 18% here ⇒ one itm per invoice); txval/camt/samt/iamt from line sums, NOT from
  printed totals. `pos` from buyer GSTIN state code. `rchrg: "N"`, `inv_typ: "R"`.
- `hsn_b2b`: derive from the same line items (single source of truth): truncate
  hsn_sc to 4 digits, bucket by hsn×rate, sum txval/camt/samt/iamt. Emit qty 0 to
  match filing convention, but keep real extracted quantities in Nila's artifact.
- `doc_issue`: from observed sequence — from/to/totnum/net_issue/cancel (gaps).
- Emit to `tmp/eval/2026-05-breeze/derived_gstr1.json`.

Normalization rules (encode in code, they will otherwise drift):
- Dates: page `04.05.2026` → filed `DD-MM-YYYY`.
- Invoice `val`: rounded to whole rupee (filed 76171 vs printed 76,171.36); txval and
  tax amounts keep paise.
- HSN: 4-digit truncation for the summary only.
- Numbers compared with ±0.01 tolerance after rounding rules.

Scored fields (raw score, field-level):
- Invoice-level: `ctin`, `inum`, `idt`, `val`, `pos`, `rchrg`, `inv_typ`; item:
  `rt`, `txval`, `camt`, `samt`, `iamt`, `csamt`.
- HSN summary (secondary score): `hsn_sc`, `rt`, `txval`, `camt`, `samt`, `iamt`.
  **Exclude qty/uqc** (filed as 0/OTH by convention).
- Doc summary (cheap, still scored): from, to, totnum, net_issue, cancel.
- Never score: `chksum`, `flag`, `updby`, `cflag`, portal-internal fields.

Output: per-field match/mismatch table, raw score %, issues list. Every mismatch gets
manually adjudicated against the page image before it's declared a Nila error.

### 4. Review-final score

- Corrections live in a patch file (e.g. `tmp/eval/2026-05-breeze/corrections.json`):
  invoice + field + corrected value.
- Hard rule: a correction is only legitimate if the field was **flagged** (low
  confidence or validation issue). Corrections to unflagged fields are **silent
  errors** — counted and reported separately, loudly. Silent errors are the
  trust-killing failure mode; the harness must not blur them into the review count.
- Re-run diff with patch applied → must reach 100% match. Report:
  raw %, number of flagged corrections, number of silent errors, final %.

### 5. Iteration honesty rules

- Allowed while tuning: schema/prompt changes encoding **general** rules (prefer line
  sums over printed totals; dates may use dots or dashes; HSN may be 4–8 digits).
- Disqualifying: anything referencing this bundle's specifics (party names, amounts,
  hardcoded fixes). If it happens, the number is void.
- Holdout months (later): run frozen, first-shot, no tweaks before scoring. Corpus
  exists — years of Breeze Tech + Caltech; portal JSON downloadable per month.
  Suggested first holdout set: one older Breeze month + one Caltech month (different
  invoice template = real generalization signal).

## Fixtures

Move `breeze_may_sales.pdf` and the returns zip (or its extracted JSON) into
`test/fixtures/gstr1/breeze/2026-05/`. Contains real GSTINs and filed data — fine for
this private repo; scrub before any open-sourcing.

## Explicitly out of scope today

- Review UI / LiveView; anything landing in `lib/` (the repurpose-in-place refactor of
  `LlamaExtract` waits until the schema is proven by this eval).
- The 16MB Excel master file (business-owner-side artifact; separate future eval).
- Portal upload mechanics (whether chksum/flag are omitted on upload) — claim is
  "structurally identical to the downloaded filing".
- Multi-page invoices, B2C, credit notes, other GSTR-1 tables — none appear in this
  bundle.

## Done means

For May 2026 Breeze: raw score + review-final score (100%) + silent-error count +
issues list (must include the page-1 poison total and the 3 sequence gaps) + a
portal-shaped `derived_gstr1.json` — every mismatch adjudicated against the page.
