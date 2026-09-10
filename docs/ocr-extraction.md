# OCR Extraction — Provider Behaviour & Findings

_Empirical record of how the OCR/extraction providers actually behave on real GST
packets, why whole-document extraction fails past a size threshold, and the design
that follows. See `lib/nila/gst/extraction/` for the code and `decisions.md` for
system-level rationale._

The extraction path turns a dumped PDF (a month of invoices, one or more per page)
into structured invoice artifacts.

> **2026-09-10:** the remaining OCR replay code and commands were removed.
> Saved experiment results remain as historical evidence.

> **Production switch, 2026-08-17.** `Nila.Gst.Extraction.VisionPipeline` now sends
> packet thumbnails to the configured vision model for segmentation and sends each
> resulting invoice's full-resolution pages back for extraction. Mistral OCR is no
> longer on the production path. The measurements below are retained as the history
> of the superseded OCR architecture and its safeguards.

> **Verification warning, 2026-08-14.** The current lexical source-presence checker
> is not accounting assurance: on labelled real invoices it deleted correct values,
> and re-verifying after deletion improved some statuses. The semantic Binder
> replacement was noisier and has been removed. Do not extend either approach
> without a labelled baseline comparison. See
> [`verification-spike-retrospective.md`](./verification-spike-retrospective.md).

## TL;DR

- **Per-page OCR is reliable and roughly linear**: ~3.5s/page cold, ~2s fixed
  overhead. It transcribes every page regardless of packet size.
- **Whole-document *annotation* (the structured invoice extraction) degrades past
  ~15 pages**: it silently **drops** real invoices and **duplicates** others, while
  still returning HTTP 200 with well-formed JSON. This is the dangerous failure —
  plausible and silent.
- **The fix for packet-level omission is segment-then-extract**: transcribe once,
  discover bill boundaries, and extract one bill per call. This makes source checks
  local to one invoice, but the current lexical checker is not semantic proof and
  must not be treated as accounting assurance.
- **Timeouts are recoverable, not fatal**: Mistral caches OCR on identical
  requests, so a retry after a client timeout returns in seconds. Retry once;
  don't fail the dump on transient transport errors.
- **Every physical page is accounted for**: an extracted invoice or confirmed
  non-invoice claims it; anything else becomes an explicit review gap.
- **Segmenting fixed *which* bills come back, not *what numbers* they carry.** A
  required-but-nullable schema field the bill doesn't print gets **invented**, and
  the invented value then propagates into fields that are printed. The fix is to
  name, in the field's description, the thing on the page the model is confusing it
  with — not to restate the rule more firmly.

## What the request actually does

One Mistral `/v1/ocr` call runs **two** different systems:

1. **OCR layer** — a vision model transcribes each page independently. Scales fine;
   per-page and indifferent to packet size. This is why `pages_processed` always
   matches the real page count and the page markdown contains the text.
2. **Annotation layer** — a language model reads *all* the OCR text at once and must
   emit one structured JSON array holding every invoice. This is the part
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

All runs used real auditor packets and Mistral `mistral-ocr-4-0` (sandbox API,
not billed), across purchase and sales schemas. The measurements below are the
historical evidence that led to the segmented production design.

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

The former 8-page chunked prototype (overlap 2, concurrent), on the same PDF:

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

> **Superseded, 2026-07-30.** Production then read packets through the now-retired
> segmented OCR pipeline: transcribe with annotation off, label each page
> against its neighbours to find the bill boundaries, then extract one bill per
> call and ground every printed number in that bill's own text. The mechanism
> below is still the reason — the annotation half of `/v1/ocr` carries the output
> budget — but windows treated it as a size problem when it was a *unit* problem:
> a window held several bills and spent one budget across them. Reading one bill
> per call removes the budget question rather than shrinking it, and makes
> hallucination checkable, since there is now text to search. Everything from here
> to §Status is the record of the path that got us there, kept because the
> measurements are still true. See `Nila.Gst.Extraction.Discovery` for why the
> per-page decider beat a whole-dump one.

## Historical chunked design

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

## Field fabrication in the structuring call (2026-08-04)

Segmenting fixed *which bills* come back. It did not fix *what numbers* come back
for a bill. A separate failure lives in the second half of the pipeline — the
text-in/JSON-out structuring call (`OpenAICompatibleChat`, then configured as
`mistral-small-latest`) — and it
is quieter than a dropped invoice, because the output is well-formed, plausible,
and blocks a filing.

### The case

Sales dump 11, page 7 (12 line items). The month page showed a blocking
"Tax total doesn't tally". Three chips, but only one was a real problem: two were
`info`-level `rounding_variance` (0.03 CGST + 0.03 SGST — the six paise), and the
blocking one compared the line-item sum (69,900.72) against a `printed_total_tax`
of **69,094.80**. The bill prints **69,900.66**.

It was not an OCR misread. The archived transcription artifact has `69,900.66` at
**99.67%** word confidence, and the table's own minimum confidence is 0.885. The
value was on the page, read correctly, and then replaced downstream.

### Mechanism

`invoice_schema/1` is sent with `strict: true`, and strict structured-output mode
requires **every** property to appear in `required` — so `strict_object/1` lists
them all (`invoice_schema.ex`). Optionality is expressed as
`anyOf: [%{type: "number"}, %{type: "null"}]`.

Formally that is correct and `null` validates cleanly: `required` constrains key
*presence*, not value non-nullity. Nothing rejects a null. But the model does not
read it that way. A required key with a `number` branch, plus per-line CGST
visible in the text, reads as an invitation to produce a number. The original
description made it worse by presupposing the value exists:

```
"Copy the invoice-level CGST summary amount exactly.
 Never calculate or allocate it from item rows."
```

*Copy X* with no mention of null offers no sanctioned exit. So the model
manufactures one: it invents an invoice-level CGST half, then derives the total
from its own invention. One run during testing returned `printed_total_tax`
= **139,801.32** — exactly 2× the truth, the doubling laid bare.

The missing null branch is only half of it, though, and the smaller half. Adding
one did **not** fix the behaviour (see the A/B below); what fixed it was naming
the **decoy**. Every one of these bills carries a per-line CGST *column*, and the
model treats that column as satisfying a request for "the invoice-level CGST".
The field it invents is a plausible aggregate of something genuinely on the page —
which is why it survives a casual read, and why the grounding check is the only
thing that ever objects.

Most bills in this corpus print no invoice-level CGST/SGST row at all. A scan of
93 archived purchase OCR pages:

| Invoice-level tax summary printed | Pages | Share |
|-----------------------------------|-------|-------|
| TOTAL row only (per-line tax)      | 76    | 81.7% |
| `Add IGST` style summary           | 13    | 14.0% |
| Neither                            |  4    |  4.3% |

So the fields must stay — 14% of bills genuinely print a summary — and `null` has
to become the expected answer for the rest.

### Prompt A/B on `mistral-small-latest`

All runs on sales dump 11; `printed_igst` and `printed_total_tax` wording held
constant throughout, so `printed_cgst`/`printed_sgst` is the only variable.
"fills" counts pages where `printed_cgst` came back non-null — on this corpus,
every such fill is fabricated.

| `printed_cgst` description                                   | n | page 7 correct | fills |
|--------------------------------------------------------------|---|----------------|-------|
| **"A single CGST amount printed once for the whole invoice, in the totals area below the item table — for example a row reading 'Add: CGST 9%' or 'Total CGST'. The CGST column inside the item table is not this. If the invoice prints no such row, return null."** | 7 | **7/7** | 26/56 |
| "…Most bills break CGST out per line and print no invoice-level CGST summary at all: return null for those, which is the expected answer, not a failure. Never derive…" | 7 | 7/7 | 0/56 |
| "…Fill this only when the bill prints a labelled invoice-level CGST total, such as 'Add: CGST 9%'; otherwise null."                | 5 | 3/5 | 23/40 |
| "…Null is the expected answer when the bill prints no such summary — not a failure."                                              | 8 | 3/8 | 39/64 |
| "…Null when the bill prints no such summary." (no negation clause)                                                                 | 3 | 1/3 | 15/24 |
| "…Null when the bill prints no such summary. Never derive it — not from item rows, not by halving a tax total."                     | 3 | 1/3 | 13/24 |

The top row is what shipped. On the full 7-run sweep it read **56/56 page totals
correctly** — every page, every run, not just page 7.

Four findings, in descending order of how much they should change behaviour:

1. **Name the decoy, not the rule.** Every failing variant is a well-formed
   instruction about *when* to fill the field, and the model ignores all of them.
   What works is a sentence pointing at the thing it is confusing this with:
   *"The CGST column inside the item table is not this."* The model was never
   failing to understand the condition — it was looking at a table full of CGST
   numbers and concluding the condition was met.
2. **Fills alone do not predict failure — fills on multi-line bills do.** The
   shipped wording still fills 26/56, but only on single-line invoices, where half
   the total *is* that line's CGST and the value is therefore correct. On the
   12-line page it returned null in all 7 runs. The earlier "fills predict failure
   one-for-one" reading came from a variant that happened to fill everywhere.
3. **The derivation identity is exact.** Across 18 runs and 4 variants,
   `printed_total_tax == printed_cgst × 2` in *every* case where `printed_cgst` is
   non-null, and the total is correct in every case where it is null — including
   one run that filed the real total as the CGST component and doubled it to
   139,801.32. The total is a pure function of the invented half.
4. **Naming the bad derivation does not induce it.** Removing "never by halving a
   tax total" slightly *increased* fills (13/24 → 15/24). No elephant effect.

A frequency claim also scores 7/7, by asserting that most bills print no such row.
It was tested and rejected: it is true of this corpus (two related businesses) and
false of bills in general, and it works by shifting a prior rather than stating
something checkable. Shipping it means the first supplier who prints "Total CGST"
gets nulled. Do not reintroduce corpus statistics into schema descriptions.

### Model size changes the direction of the error

Before the wording above was found, `mistral-medium-latest` was measured as an
alternative (n=3, plain description): page 7 correct 3/3, grounding flags 6 → 1.
Superseded as a recommendation — small is sufficient with the right description —
but the mechanism is worth keeping:

- **small** — invents a CGST half, doubles it into the total. Corruption flows
  *upward* into the field the arithmetic checks consume.
- **medium** — reads the printed total correctly, then halves it into the
  components. Corruption flows *downward* into fields little depends on.

Every medium fill was exactly half the total. On the one 12-line page where it
halved, `value_not_on_page` fired correctly, because 34,950.33 appears nowhere on
the bill. The grounding check already has the signal — it is recorded as a note
rather than acting as a gate.

### `Add IGST` regression — passes

`printed_igst` wording was held constant throughout and **not** given the same
treatment, because it does not need it. Purchase dump 2 (Caltech, 2026-06, 15
pages, n=3): the four bills printing `Add IGST : 18%` were captured on every run
(48,801.60 / 4,599 / 5,445 / 6,073.20), and pages where "IGST" appears only as an
HSN-summary *column header* correctly returned null. The `cgst`/`sgst` rewording
does not bleed across fields. Changing a field that passes, for symmetry with one
that failed, is how you acquire a new bug.

`printed_total_taxable` still carries the original *"Copy … exactly"* shape with
no null branch — the same defect that caused this bug. It has not misfired,
because every bill in this corpus prints a taxable total, so the model has never
had to invent one. Untested, not proven.

### Methodological note

n=3 is not enough to compare prompt variants here. The "expected … not a failure"
variant scored 3/3 on its first three runs and 3/8 over eight — the first result
was luck. Page-7 correctness gives one observation per run; the fill rate gives
eight. **Score on fills, and run ≥7.** Several conclusions in this session drawn
from n=3 had to be withdrawn.

Note also that dump 11 yields only *one* page of real signal per run: pages 3, 4,
5 and 8 are single-line invoices where a fabricated half is arithmetically correct
anyway, so only the 12-line invoice 44/2026-27 can expose the fault. More
multi-line bills belong in the eval set before any of this is trusted broadly.

### Run-to-run coverage variance

Identical input, back-to-back runs of purchase dump 2 returned 9 invoices
(covering pages 1–10) and then 14 (covering all 15). Worth chasing — but it is
**not** a silent drop. `unaccounted_pages` (`segmented.ex:411`) diffs extracted
`source_pages` against every transcribed page and the flags layer raises
`pages_unaccounted`, so the short run reports pages 11–15 rather than passing a
truncated return off as complete. The ledger is blind only if pages are lost
during *transcription*, since it takes its page universe from the transcript
itself — that gap is real but has not been observed.

### Open

- Give `printed_total_taxable` a null branch, and re-measure.
- Make `value_not_on_page` a gate for `printed_*` fields — null an ungrounded
  component instead of storing it — rather than a note. 5 flags survive on the
  shipped wording.
- Reconsider `cgst_equals_sgst` / `tax_components_sum` when the components they
  consume are ungrounded.
- Add multi-line bills to the eval corpus; one signal page per dump is too thin.
- Chase the coverage variance, and confirm whether transcription-stage page loss
  can evade the ledger.

## Status

- [x] **Direct vision shipped and switched on** (2026-08-17):
      `Nila.Gst.Extraction.VisionPipeline` is the sole production reader.
- [x] Evidence rendering lives independently in `Nila.Gst.Extraction.Evidence`.
- [x] Every extracted value is grounded through `Nila.Gst.Extraction.Verify`.
- [x] Provider behaviour was characterised and whole-packet degradation was
      reproduced and root-caused (this document).
- [x] Eval packets live in the private `nila-eval-corpus` R2 bucket;
      `eval/corpus.json` is the registry and segmented attempts are the only
      extraction attempts scored by `mix nila.eval`.
- [ ] Suspicious-table crop/retry for handwritten nested totals (separate failure;
      see the `84418` case — full-page decoder omits a nested footer the model reads
      correctly when cropped).
- [x] **Invoice-level `printed_cgst`/`printed_sgst` fabrication fixed** (2026-08-04):
      `mistral-small-latest` was inventing an invoice-level CGST half and doubling it
      into `printed_total_tax`. Fixed in the schema description by naming the decoy —
      "The CGST column inside the item table is not this" — which reads 56/56 page
      totals correctly over 7 runs. No model change, no corpus statistic. See the
      section above.
- [ ] `printed_total_taxable` still has no null branch (same defect shape, not yet
      triggered because every bill in the corpus prints a taxable total).

## Experiment log

These historical probes were removed after their findings were captured here.
Two earlier one-offs were also removed once
their results were captured here: a timing probe (annotation is *not* the latency
cost — plain OCR ≈ OCR+features ≈ full annotation, ~1–1.4s/1p) and a nov-resend probe
(the 15p timeout was tail variance, not a pathological doc — warm cache returned all
15 in 3.1s).

| Date       | Historical probe               | Question                                  | Result                                                        |
|------------|--------------------------------|-------------------------------------------|---------------------------------------------------------------|
| 2026-07-23 | `omission.exs`                 | Does whole-PDF drop invoices ≤15p?        | No silent omission at ≤15p; one recoverable timeout.          |
| 2026-07-23 | `cold_latency_curve.exs`       | Cold latency vs. size?                     | ~linear, ~2s + ~3.5s/page.                                    |
| 2026-07-23 | `whole_packet_canary.exs`      | Does the 57p packet still drop invoices?   | Yes — RAC2451 dropped, 39 dup entries, HTTP 200. Threshold confirmed. |
| 2026-07-26 | `whole_packet_canary.exs` (windowed) | Does windowing recover RAC2451?      | Yes — 47–48 unique vs 34, no hallucinated dupes, true miss on p41 flagged. 42s at concurrency 16. |
| 2026-07-26 | ad-hoc (fresh 28p packet)      | Does windowed hold on unseen data?         | Clean: 25/25 unique, 36s cold, non-invoice pages flagged. |
| 2026-07-26 | canary re-run ×2               | Do window requests warm-cache?             | No — identical windows re-ran cold (~42s). Budget windowed runs as cold. |
| 2026-08-04 | `reextract.exs` (dump 11)      | Does page 7's bad tax total reproduce?     | Yes, every run. Not OCR — the transcript holds 69,900.66 at 99.67% confidence. |
| 2026-08-04 | `survey_formats.py` (93 pages) | Do our bills print invoice-level CGST/SGST?| No: 81.7% TOTAL-row only, 14.0% `Add IGST`, 4.3% neither. Null must be a valid answer. |
| 2026-08-04 | `eval_prompt.exs` ×5 variants  | Can prompt wording stop the fabrication?   | Rule-shaped framings ("null when…", "expected, not a failure", "only when labelled") all fail on small. |
| 2026-08-04 | `eval_prompt.exs` (medium)     | Is it the model rather than the prompt?    | Medium, honest wording: 3/3 correct, flags 6→1, and the corruption reverses direction. |
| 2026-08-04 | `eval_prompt.exs` (decoy wording) | Does naming the item-table column fix it? | Yes — 56/56 page totals over 7 runs on small. Superseded the medium recommendation. |
| 2026-08-04 | `eval_prompt.exs` (purchase d2) | Does the rewording suppress `Add IGST`?   | No — 4/4 interstate bills captured on 3/3 runs; HSN column headers correctly nulled. |
