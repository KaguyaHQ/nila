# OCR Extraction — Provider Behaviour & Findings

_Empirical record of how the OCR/extraction providers actually behave on real GST
packets, why whole-document extraction fails past a size threshold, and the design
that follows. See `lib/nila/gst/extraction/` for the code and `decisions.md` for
system-level rationale._

The extraction path turns a dumped PDF (a month of invoices, one or more per page)
into structured invoice artifacts. Mistral OCR is the operational default;
LlamaExtract is a benchmark-only adapter (prohibitively costly). Provider selection
is explicit via `GST_OCR_PROVIDER`, with no automatic fallback.

## TL;DR

- **Per-page OCR is reliable and roughly linear**: ~3.5s/page cold, ~2s fixed
  overhead. It transcribes every page regardless of packet size.
- **Whole-document *annotation* (the structured invoice extraction) degrades past
  ~15 pages**: it silently **drops** real invoices and **duplicates** others, while
  still returning HTTP 200 with well-formed JSON. This is the dangerous failure —
  plausible and silent.
- **The fix is chunking**, not a provider change: small page windows keep the
  annotation step inside the context length where it stays reliable. Chunk + verify
  page coverage so any residual drop is loud, never silent.
- **Timeouts are recoverable, not fatal**: Mistral caches OCR on identical
  *requests* (same bytes AND same parameters), so a retry after a client timeout
  returns in seconds. Retry on timeout; don't fail the dump. **Caveat learned
  later**: windowed subset requests do NOT hit this cache across runs — assume
  every window pays cold OCR (§Evidence 5).
- **Windowed extraction passes acceptance**: on the 57-page canary the windowed
  path recovers the dropped invoice, extracts 47–48 unique (vs 34), hallucinates
  nothing, and flags genuinely problematic pages for review (§Evidence 5–6).

## What the request actually does

One Mistral `/v1/ocr` call runs **two** different systems:

1. **OCR layer** — a vision model transcribes each page independently. Scales fine;
   per-page and indifferent to packet size. This is why `pages_processed` always
   matches the real page count and the page markdown contains the text.
2. **Annotation layer** — a language model reads *all* the OCR text at once and must
   emit one structured JSON array holding every invoice (schema in
   `Nila.Gst.Extraction.Providers.Mistral.annotation_schema/1`). This is the part
   that breaks on long input.

The strict JSON schema constrains the **shape** of each invoice object, not the
**completeness or uniqueness** of the array — so drops and duplicates are both
unconstrained by design.

## Why whole-packet extraction breaks (mechanism)

Standard long-context LLM failure, not a Mistral bug:

- **Attention dilution / "lost in the middle."** A fixed attention budget spread
  across dense tabular text starves any single invoice; middle-of-packet content is
  easiest to lose.
- **Output degeneration.** Deep into a long JSON array the model pattern-completes
  ("I've been emitting invoice objects, keep emitting") instead of carefully reading
  — the source of duplicate entries.
- **No input→output enforcement.** Nothing guarantees "every distinct invoice in →
  exactly one object out."

This is textbook for *any* LLM extractor (Mistral, GPT, Claude). Whole-packet worked
at ≤15 pages by luck: the context was short enough to stay in the reliable zone.
Chunking isn't a workaround — it's keeping each request inside the context length
where the model behaves.

Vendor context that corroborates this: Mistral's annotation feature had a **hard
8-page cap until January 2026** ("Document Annotations update and improvements, 8
page limit removed" — their changelog). The cap was removed without any replacement
quality guarantee or degradation warning; their own cookbooks still say "we
recommend spliting your documents", and partner deployments (Azure Foundry, Vertex)
still enforce 8–30-page caps. Our 8-page window matches the size Mistral itself
considered safe when it enforced one. Additionally, the annotation model receives
only the **first 8 image bounding boxes of the whole document** (their FAQ) — in a
long document, pages past the first few are annotated from OCR text alone, with no
visual signal; in an 8-page window, every page's crops fit the budget.

A related finding: the annotation's `source_pages` attribution is unreliable at
length — on the 57p whole call a pages-20–21 invoice was tagged `[1,2]`, and even
within 8-page windows occasional implausible page sets appear (a 1-page invoice
claiming `[20, 25, 28]`). Treat model attribution as a hint; the deterministic
evidence check (`resolve_source_pages`) and the page ledger are the guards.

## Evidence

All runs against real auditor packets, Mistral `mistral-ocr-4-0` (sandbox API,
not billed), purchase and sales schemas. Reusable probe scripts in
`scripts/ocr_probes/` (see its README); raw artifacts under `tmp/mistral_*_probe/`.

### 1. Recall on small/medium packets — clean

Whole-PDF extraction vs. filed GSTR-1 ground truth (`inum` list in the
`returns_*_R1_*.json` fixtures):

| Packet          | Pages | Truth | Extracted | Verdict                                    |
|-----------------|-------|-------|-----------|--------------------------------------------|
| breeze 2026-01  | 8     | 8     | 8         | OK                                         |
| breeze 2026-05  | 15    | 15    | 15        | OK                                         |
| caltech 2025-10 | 6     | 6     | 6         | OK                                         |
| caltech 2025-11 | 15    | 15    | 15\*      | OK (\*after cache warm; see timeout note)  |
| caltech 2025-12 | 4     | 3     | 4         | +1 real invoice (120/2025-26) not in filing|
| caltech 2026-01 | 6     | 6     | 6         | OK                                         |

No silent omission at ≤15 pages. The caltech-12 "extra" is a genuine invoice on
page 3 (Siemens, IGST ₹32,730) that simply wasn't in that month's R1 — extraction
was *more* complete than the filing, not hallucinating.

### 2. Cold latency vs. size — ~linear, ~3.5s/page

Fresh, never-sent purchase docs, one shot each (no cache contamination):

| Pages | Bytes | Cold ms | s/page |
|-------|-------|---------|--------|
| 1     | 358K  | 5,802   | 5.8    |
| 3     | 587K  | 11,642  | 3.9    |
| 8     | 1.0M  | 27,818  | 3.5    |
| 9     | 1.2M  | 28,634  | 3.2    |
| 13    | 4.2M  | 47,002  | 3.6    |

Roughly linear: ~2s fixed + ~3.5s/page. **The annotation step adds almost nothing** —
a controlled per-page comparison (plain OCR vs. OCR+features vs. full annotation) was
~1–1.4s for all three variants on the same single page. The wall-clock cost is cold
OCR, and it scales with pages, **not** with invoices or annotation.

### 3. Warm cache — timeouts are recoverable

caltech-11 (15p, 5.3M) timed out at our 300s client `receive_timeout` on first cold
send. **Resent: 3,121ms, all 15 invoices (103–117), complete.** The server had
already OCR'd it; the client just gave up before the response arrived, and the result
was cached on the document bytes. → A timeout should trigger a cheap retry (warm
cache), never a dump failure.

### 4. The 57-page packet — the breaking point, reproduced

Breezetech October, 57 pages, 12M. This is the canary: invoice **RAC2451** on page
51 was dropped in an earlier session and **still drops** on a fresh run.

```
pages_processed:        57    (OCR read every page)
RAC2451 in OCR page 51: YES   (text is in the page markdown)
RAC2451 in annotation:  NO    ← silently dropped
annotation invoices:    73
unique invoice numbers: 34    (73 entries collapse to 34 real)
duplicated entries:     39 extra dupes across 20 invoice numbers
```

The annotation degrades in **both** directions at once: it omits real invoices *and*
hallucinates duplicates (261997 ×12 plus ×3 under a garbled variant, CH/CR-6277 ×7),
returns HTTP 200, no error. The
per-page OCR was perfect — only the "reason over everything at once" step failed.
This is the definitive proof that whole-packet extraction is unsafe past the
threshold (somewhere between 15 and 57 pages).

### 5. Windowed acceptance on the same 57-page packet — passes

`Nila.Gst.Extraction.Windowed` (8-page windows, overlap 2, concurrent), same PDF:

```
                    whole call          windowed
invoices returned   73 entries          53–54
unique              34                  47–48
RAC2451             DROPPED             present
hallucinated dupes  39 excess entries   0 (repeats = real duplicate scans)
missed pages        invisible           flagged for review
wall clock          ~200s               42s (concurrency 16) / 107s (4)
```

The repeated numbers that remain are genuine duplicate scans in the packet
(disjoint pages), correctly left to the `duplicate_invoice` review flag. The
flagged unaccounted pages across runs: a misattributed-but-extracted invoice
(noise, safe side), a blank e-invoice continuation sheet (correct), and — on one
run — a genuinely missed, badly blurred phone-photo invoice (City Makson
CME/0642/25-26, page 41): **the ledger surfacing a true miss that the whole call
would have swallowed silently.** Run-to-run annotation variance on marginal pages
is real; the guards make it visible either way.

Cache correction: windows are *not* warmed by prior whole-document runs, and
re-running identical windows minutes later still paid cold OCR (~42s, not ~5s).
The warm cache observed on whole-document resends does not extend to page-subset
requests (or expires quickly). Budget every windowed run as cold.

### 6. Fresh 28-page packet — clean end-to-end

Breezetech June 2026 (28p, never sent before): 36s cold, 5 windows, 25 invoices,
all unique, zero dupes, multi-page invoice on pages 1–2 assembled inside its
window. Three pages flagged: Porter-style trip receipts (app screenshots, zero
GST) that produced no invoice — correct review-flag behaviour. Notable
inconsistency: two later pages of the *same* receipt type were instead extracted
as zero-tax invoices — the model's "is this an invoice" threshold wobbles on
non-invoice pages; either path is safe (flag or zero-tax record), but review sees
both shapes.

## Design mandate — shipped as `Nila.Gst.Extraction.Windowed`

Grounded in the evidence above, not theory:

1. **Chunk into small page windows.** 8-page windows keep each request in the clean
   regime (≤15p never dropped) at ~3.5s/page ≈ 30s cold — comfortably under any sane
   timeout, and far from the degradation zone. 8 also matches Mistral's own
   historical annotation cap.
2. **Overlap by 2 pages.** A multi-page invoice at a boundary is fully contained in
   one window and re-seen in the next, so nothing falls in a crack. GST invoices are
   1–2 pages, so overlap-2 covers essentially everything.
3. **Dedupe on `(seller_gstin, invoice_number)`.** Overlap and the model's own
   duplication both produce repeats; a stable identity key collapses them. The 57p
   run proves dedupe is mandatory even for a *single* call. Only records whose
   pages **touch** collapse — that is the mechanical echo. The same number on pages
   that don't touch stays two records and reaches the `duplicate_invoice` flag,
   which is the business question ("scanned twice?"), not the mechanical one.
4. **Timeout → retry per chunk.** Retries hit the warm server-side cache and return
   in seconds. Idempotent and cheap. One retry, then the window's page range fails
   the dump — no partial-success months.
5. **Skipped-page ledger.** Every physical page must appear in at least one chunk's
   extracted `source_pages`, or it's flagged. This is the guard that turns a silent
   RAC2451 drop into a visible "page 51 unaccounted" review flag. Chunking shrinks
   the failure probability; the ledger makes any residual failure loud.

Chunking makes LLM extraction *reliable enough plus auditable*, not perfect — the
model is probabilistic. Belt (chunk to stay in the good zone) and suspenders (verify
page coverage).

Shape as built: page count from `pdfinfo` (poppler is installed in the runtime
image for it), windows planned 1-based and converted to the API's 0-indexed
`pages` at the call boundary, `Task.async_stream` at concurrency 4, one
`gst_extraction_attempts` row per window carrying its page range in
`request_metadata`, and unaccounted pages surfacing as a month-level
`pages_unaccounted` review flag (purchase) / issue (sales). A packet of ≤8 pages,
or an image, is still one whole-document call — small packets are proven clean.

## Status

- [x] Provider behaviour characterised (this document).
- [x] Whole-packet degradation reproduced and root-caused.
- [x] Chunker (windows + overlap + dedupe + retry + skipped-page ledger) — built as
      `Nila.Gst.Extraction.Windowed`, covered offline in
      `test/nila/gst/extraction/windowed_test.exs`.
- [x] Live acceptance against the 57-page canary — passed (Evidence 5). Verified
      again on a fresh 28-page packet (Evidence 6).
- [x] Eval packets moved out of git into the private `nila-eval-corpus` R2 bucket;
      `eval/corpus.json` is the registry (sha256 + ground-truth mapping),
      `mix nila.eval_corpus` pulls/pushes. Probes resolve packets by corpus name.
- [ ] Hallucination check — every extracted invoice_number must appear in the
      window's page markdown (exact search of a known string); absent ⇒ review
      flag. The symmetric miss-direction guard (harvest candidates from markdown)
      was **measured and rejected**: invoice numbers in this corpus share no regex
      shape (`045`, `1018`, `825/25-26`, `TI-AN-25-26-1339`), ~⅓ sit in bare
      table cells with no label anchor — label-anchored ≈ 62% recall, shape-based
      ≈ ~57 junk candidates/packet. The hole it would cover (partial drop on a
      multi-invoice page inside a window) has not occurred in any measured packet;
      single-invoice-page drops produce zero artifacts and the ledger catches them
      (page 41, Evidence 5). Revisit only on real-packet evidence — details in
      `docs/.plans/2026-07-26-windowed-extraction.md` §4.
- [ ] Suspicious-table crop/retry for handwritten nested totals (separate failure;
      see the `84418` case — full-page decoder omits a nested footer the model reads
      correctly when cropped).

## Experiment log

Append new probes here so the record stays extensible. Keep raw output under
`tmp/` and the script under `scripts/`.

Retained probes live in `scripts/ocr_probes/`. Two spent one-offs were removed once
their results were captured here: a timing probe (annotation is *not* the latency
cost — plain OCR ≈ OCR+features ≈ full annotation, ~1–1.4s/1p) and a nov-resend probe
(the 15p timeout was tail variance, not a pathological doc — warm cache returned all
15 in 3.1s).

| Date       | Probe (`scripts/ocr_probes/`)  | Question                                  | Result                                                        |
|------------|--------------------------------|-------------------------------------------|---------------------------------------------------------------|
| 2026-07-23 | `omission.exs`                 | Does whole-PDF drop invoices ≤15p?        | No silent omission at ≤15p; one recoverable timeout.          |
| 2026-07-23 | `cold_latency_curve.exs`       | Cold latency vs. size?                     | ~linear, ~2s + ~3.5s/page.                                    |
| 2026-07-23 | `whole_packet_canary.exs`      | Does the 57p packet still drop invoices?   | Yes — RAC2451 dropped, 39 dup entries, HTTP 200. Threshold confirmed. |
| 2026-07-26 | `whole_packet_canary.exs` (windowed) | Does windowing recover RAC2451?      | Yes — 47–48 unique vs 34, no hallucinated dupes, true miss on p41 flagged. 42s at concurrency 16. |
| 2026-07-26 | ad-hoc (fresh 28p packet)      | Does windowed hold on unseen data?         | Clean: 25/25 unique, 36s cold, non-invoice pages flagged. |
| 2026-07-26 | canary re-run ×2               | Do window requests warm-cache?             | No — identical windows re-ran cold (~42s). Budget windowed runs as cold. |
