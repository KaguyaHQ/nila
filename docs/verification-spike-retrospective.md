# GST Verification Spike — Retrospective and Handoff

> **Status:** historical. OCR replay and source-quality commands were removed on
> 2026-09-10. Saved results and human reviews remain; commands below describe the old code.
> **Date:** 2026-08-14
> **Repository snapshot at close:** `main` and `origin/main` at `ef1b8e5`
> **Audience:** the next engineer touching GST extraction, verification, or source-quality routing

## Executive verdict

The attempted evidence verifier did not improve Nila on the labelled Breeze October
purchase sample. It added a semantic regex `Binder`, invoice-wide `Readiness`, a
second arithmetic engine, source-span machinery, and downstream telemetry before
proving that the central rules discriminated correct from incorrect extraction.

The experiment was removed from `main`. Do not recreate it.

The useful result retained on `main` is an eval-only source-quality report. It reads
cached OCR confidence, including nested table words, and ranks pages for human
calibration. It has no production threshold, routing, review flag, or authority.

The existing production verifier is not thereby endorsed. It still has a known
failure mode: a lexical source-presence false negative can delete a correct value,
after which the smaller invoice is verified again and can receive a better status.
That is the next narrow safety question, but it must be measured before it is
changed.

## Repository state at close of the 2026-08-14 session

At the close of this session, `main` and `origin/main` pointed to:

```text
ef1b8e5 feat(eval): add source quality report
2c89ce1 feat(extraction): default discovery to paper context
60c9977 feat(extraction): evaluate paper-style page context
7ed4953 feat(extraction): support swappable text providers
```

At that point, only `main` existed locally. The verifier spike branches were
deleted after the source-quality report was isolated and squash-committed.

These commits are not ancestors of `main`:

```text
e5e09c0 fix(extraction): preserve failed verification evidence
0d1b465 feat(gst): add OCR evidence index
2739d61 feat(extraction): add shadow evidence verification
6e58915 chore(eval): archive verifier experiments
```

They may remain temporarily recoverable by object ID in the local Git object store,
but no work should depend on that. They were never pushed.

The push of `ef1b8e5` passed the pre-push suite:

```text
1,249 passed
2 excluded
```

The deployment status after the push was not checked. The commit changes eval code
only; `lib/nila/gst/**` is byte-identical to `2c89ce1`.

## What shipped

### Provider and segmentation work

The production extraction path before this retrospective already had:

- a configurable OpenAI-compatible text provider;
- Qwen no-thinking support with local JSON Schema validation;
- provider admission, concurrency limits, token accounting, and cooldown;
- no conversion of provider/transport failure into document meaning;
- no partial publication;
- deterministic page grouping with paper-style head/tail context.

The canonical Qwen extraction run over the cached OCR 4.1 transcription of the
57-page Breeze packet produced:

```text
57 pages
54 segments
53 extracted invoices
118 seconds
approximately $0.016
0 provider failures
```

There are 54 human invoice segments. Page 38 was unaccounted because OCR 4.1
confidently omitted its whole item/tax table. This is a completeness failure, not a
source-confidence or semantic-verification success.

### Eval-only source-quality report

Commit `ef1b8e5` adds:

```text
eval/source_quality/breeze-2025-10-purchase.json
lib/nila/eval/source_quality.ex
mix nila.eval source-quality <name> --transcription-attempt DIR
```

The report computes metrics only when the eval command runs. Production
transcription does not calculate or persist them.

Current metrics:

- all-word count;
- all-word mean confidence;
- all-word P10 confidence;
- share of words below 70%;
- provider page-average confidence for comparison.

The human fixture covers pages 1–40 and is explicitly incomplete:

```text
visual quality:       25 good, 14 degraded, 1 unusable
critical readability: 24 comfortable, 8 effortful, 8 unreliable
```

In the pilot, the nine lowest all-word-mean pages were all non-Fine; the first Fine
page ranked tenth. This is in-sample evidence, not a production threshold.

Important boundaries:

- page 10 is globally foggy and ranks near the bottom: source-quality metrics help;
- page 5 is visually good but has critically unreadable handwriting: global
  confidence does not solve it;
- page 38 is visually clear with high confidence but OCR omitted the table:
  confidence cannot prove completeness.

## What was discarded

### `e5e09c0`

This 96-line safety commit contained good intentions and mixed behaviour.

It correctly addressed some narrow cases:

- a positive value no longer matched a plain leading-minus form such as `-425`;
- adjacent table cells were no longer merged into one number;
- incomplete line arithmetic was no longer treated as complete;
- post-deletion verification no longer hid the original failure.

It did not solve sign handling generally: a positive value could still match an
accounting-parentheses form such as `(425)`, while valid invoice notation was newly
rejected.

As a whole it regressed labelled data because generic sign syntax does not model
Indian invoice notation:

```text
180-       can mean ₹180/-, not negative ₹180
360-       can mean ₹360/-, not negative ₹360
(-)0.13    is an explicitly negative rounding adjustment
- 516.88   is often stored as positive discount magnitude 516.88
```

The commit was therefore not retained. Its individual ideas must not be
cherry-picked without the same corpus comparison.

### `EvidenceIndex`

`0d1b465` added exact numeric tokenization, signs, kinds, and source locations. It
had no production call site by itself and caused none of the authoritative
regression. It became infrastructure for the later Binder.

It was removed because no current production consumer earned the subsystem. OCR
4.1 also exposes native tables, blocks, and confidence, so future source IDs should
be assigned over native units rather than reconstructed from flattened Markdown.

### `Binder`

The 604-line Binder attempted to infer semantic roles from:

- broad labels such as `Value`, `Amount`, `Total`, and `Rate`;
- distance from labels;
- guessed table rows and columns;
- hard-coded GST summary ordering;
- item descriptions and HSN reconstruction;
- any compatible occurrence found anywhere in the segment.

This rebuilt a brittle invoice extractor around the LLM selected to avoid brittle
layout parsers. It was both noisy and unsafe: it rejected many correct claims while
still grounding wrong-role values.

### `Readiness`

Extraction-wide `ready`, `needs_review`, and `unverifiable` verdicts mixed source
interpretation with business authority. Extraction cannot decide whether an invoice
is ready for purchase accounting, ITC, GSTR-1, GSTR-3B, or filing. Those decisions
need external records, GST policy, human resolutions, and filing state in Phoenix.

The module was removed rather than renamed into another speculative capability
matrix.

### Evidence nomination

The two-pass Qwen nomination experiment used fixed candidates plus line/cell source
IDs and deliberately corrupted claims. It was the correct experiment shape, but the
available run was tied to OCR 4.0 candidates and did not pass its continuation goal:

```text
224 claims
semantic precision: 0.7701
useful coverage: 0.9351
synthetic corruptions rationalized: 1/24
unknown source IDs: 0/204
```

The fixture semantics were corrected afterward to separate scan truth, OCR truth,
and catalog support, and OCR 4.1 materially changed the candidates. No production
contract should be based on this run. The code and fixture were not retained on
`main`.

## Deterministic A/B/C comparison

### Question

Did the safety commit or the full shadow verifier improve yesterday's verifier on
our own labelled data, using identical model output?

### Fixed inputs

No provider calls were made. Every revision received the same OCR 4.0 response and
the same 53 immutable Qwen candidates.

```text
A: 2c89ce1  production baseline
B: e5e09c0  safety commit only; no Binder
C: 2739d61  safety commit plus shadow Binder/Readiness
```

Input hashes:

```text
Qwen candidate:
d43597c754e9c1ccbd5ba0041422c0bd63bbddb0d5fa8eb7ea8148687161a087

OCR response:
142c78986c78ca9d1e8bf6d42233302e9afc32296d43c699b4d4d1d63da1b104

Human fixture used by the run:
6bf4900abe3a944b75b8b1d91c5be1a761299492d0a5579525755b06baede226
```

The human sample contained 15 invoices and 200 organic claims:

```text
170 scan-correct candidates
17 semantic extraction errors with correct OCR
13 OCR-origin errors
```

The old fixture and A/B scripts are no longer tracked. Local temporary artifacts
may still exist:

```text
/tmp/nila-verifier-ab-report.json
/tmp/nila-verifier-result-A.json
/tmp/nila-verifier-result-B.json
/tmp/nila-verifier-result-C.json
/tmp/verifier_ab_run.exs
/tmp/verifier_ab_score.py
```

Treat them as ephemeral. A future authoritative comparison needs a durable,
reviewed fixture recreated under `eval/`; do not cite a `/tmp` file as permanent
evidence.

### Results

| Metric | A: baseline | B: `e5` | C: full spike |
|---|---:|---:|---:|
| Correct claims retained unchanged | **159/170** | 157/170 | 156/170 |
| Correct claims removed | **11** | 13 | 12 |
| Semantic errors caught | 1/17 | 1/17 | 1/17 |
| OCR-origin errors rejected | 10/13 | 10/13 | 10/13 |
| Verified artifacts | 38 | 30 | 30 |
| Flagged artifacts | 13 | 22 | 22 |
| Unverifiable artifacts | 2 | 1 | 1 |

C normalized two correct GSTINs, so its effective correct preservation was roughly
158/170. It still did not beat A.

A's lower flagged count was partly dishonest:

```text
candidate result before deletion: 22 flagged
published result after deletion:  13 flagged
```

Nine artifacts appeared better because failed values had been removed and the
smaller artifact was verified again.

B recovered four correct labelled fields that A had deleted, but newly deleted six
correct fields. It did not catch an additional semantic error at field level.

### Concrete failures

#### Baseline adjacent-cell merge

Page 1 OCR contained separate table values:

```text
268.26 | 268.26 | 2980.80
```

The baseline normalizer removed whitespace between digits globally and produced a
combined numeric run resembling:

```text
268.26268.262980.80
```

The source checker could no longer find standalone CGST, SGST, or taxable values,
so it set all three to `nil`. Purchase normalization then produced zero CGST and
SGST from a correct Qwen candidate.

#### `e5` trailing-hyphen regression

Page 5 OCR contained:

```text
RATE 180-
AMOUNT 360-
```

The invoice uses the dash as zero-paise notation. `e5` interpreted it as a negative
sign and deleted the correct unit price, line amount, and subtotal. The normalized
purchase value became ₹0.

#### `e5` explicit accounting-sign regression

Pages 31 and 52 contained:

```text
ROUNDED OFF (-)0.13
Less ROUND OFF (-)0.01
```

The new variants recognized `-0.13`, `(0.13)`, and `0.13-`, but not `(-)0.13`.
Both correct adjustments were declared absent and deleted.

#### Binder false support

Against catalog-support labels, Binder produced:

```text
true supported claims grounded: 108/168
useful coverage:                64.3%
false supports:                 6/32 abstains
grounded precision:             94.7%
readiness:                       2 ready, 50 needs_review, 1 unverifiable
```

Five of the six false supports were semantic extraction errors: wrong line amount,
wrong total tax, wrong taxable total, wrong CGST, and wrong SGST. These are exactly
the cases Binder was intended to catch.

The exact arithmetic shadow raised no alarm on six clean sampled invoices and
raised alarms on two of seven invoices with semantic errors. Both were already
flagged by the baseline verifier, so this did not demonstrate incremental product
value.

## Current production risk

`main` still contains the baseline verifier in:

```text
lib/nila/gst/extraction/verify.ex
lib/nila/gst/extraction/segmented.ex
lib/nila/gst/purchase/books.ex
```

The relevant flow is:

```text
candidate
→ Verify.invoice
→ Verify.discard_unobserved_values
→ verify the reduced data again
→ Books.clear_unobserved during purchase normalization
```

Consequences:

- the original provider candidate is not preserved in the v1 artifact;
- a lexical false negative can become an actual `nil` accounting field;
- purchase normalization has a second clearing path;
- deleting failed evidence can improve the published verification status;
- extraction warnings are not reliably visible as accountant exceptions.

Do not call this `verified` accounting truth. It is existing production behaviour,
not an endorsed design.

A previous real case still motivates some form of source check: Qwen returned a
taxable value of `62,552` when no such number occurred in the invoice. But that
case does not justify a generic semantic verifier or destructive sanitation. A
source diagnostic must earn low false-alarm rates and must never erase the original
claim.

## Existing 2B recovery machinery

Do not build another GSTR-2B recovery subsystem. Nila already has the canonical
implementation:

```text
lib/nila/gst/purchase/reconciliation.ex
lib/nila/gst/purchase/workings.ex
lib/nila/gst/purchase/resolutions.ex
```

It already supports:

- exact GSTIN + invoice-number matching;
- relaxed number matching with date/value corroboration;
- value/date candidates when numbers disagree;
- ambiguity instead of guessing;
- manual pair confirmation and rejection;
- field corrections followed by canonical re-reconciliation;
- append-only resolutions;
- unmatched books and 2B residuals.

Future source recovery should feed this path, not duplicate it. What is missing is
a proven, low-noise extraction/source exception—not a second matching engine.

## Lessons

### Measure before architecture

For an uncertain detector:

```text
state the hypothesis
→ define labelled truth
→ run the smallest falsification experiment
→ compare to baseline
→ implement only after it wins
```

The spike reversed this order. Unit tests proved that the rules implemented
themselves, not that the rules understood invoices.

### Shadow mode limits damage, not cost

Shadow code still adds runtime, schemas, telemetry, downstream plumbing, snapshot
filtering, tests, and maintenance. `authoritative: false` is not an Occam exemption.

### Tests can fossilize guesses

A unit test such as `number near CGST → grounded` preserves a heuristic. It does not
establish that the heuristic is correct across real invoice layouts. Semantic
heuristics require corpus tests with human truth and holdouts.

### Deterministic code should remain mechanical

Good deterministic responsibilities:

- JSON Schema validation;
- exact arithmetic with complete operands and explicit unknowns;
- GSTIN grammar/checksum;
- page conservation and segment locality;
- validating that a nominated source ID exists;
- lexical equality, kind, and sign after invoice notation is explicitly parsed;
- external 2B comparison.

Bad deterministic responsibilities:

- deciding what generic headings such as `Value` or `Amount` mean;
- guessing semantic roles from distance;
- reconstructing arbitrary table rows from descriptions and HSNs;
- treating any compatible occurrence as proof;
- inventing invoice-wide accounting readiness.

### Candidate, evidence, and business authority are different

- The model candidate is an immutable claim.
- Source evidence can support or contradict the claim but is not scan truth.
- Arithmetic can show consistency but not source presence or semantic role.
- OCR confidence is a risk signal, not a correctness certificate.
- Phoenix combines extraction facts, 2B, policy, human resolutions, and filing
  state to decide business actions.

### Failure is not unreadability

Provider, transport, decode, and schema failures are processing failures. They must
not be converted into document classifications such as `unreadable`.

### Confidence detects trash, not omission

Low all-word confidence is useful for globally poor scans. High confidence cannot
prove that OCR included every row or footer. Completeness and source quality remain
separate axes.

## Tomorrow's handoff

### First: do not write another verifier

Read this report, then inspect the three current mutation points:

```text
Verify.invoice/3
Verify.discard_unobserved_values/2
Purchase.Books.clear_unobserved/2
```

Do not start by editing them. First define the intended product outcome:

- Is a failed source-presence check only diagnostic?
- Does it create a human exception?
- May its candidate still enter books or reconciliation?
- Which action is held when the check is unresolved?

Without those answers, removing deletion may silently pass hallucinations while
keeping deletion silently destroys correct values.

### Recreate durable truth before changing behaviour

The prior 200-claim fixture was intentionally not merged. If verification work
resumes, recreate or carefully recover and re-review a minimal fixture under an
explicit `eval/verification/` contract. Before implementation, split it by invoice
into a development set and a frozen blind holdout. Do not inspect or tune against
the holdout until the rule and its continuation criteria are written down.

The fixture must distinguish:

```text
candidate correct against scan?
OCR correct against scan?
source catalog supports candidate?
field is actually checked by this validator?
```

Do not score OCR-origin errors as failures of a text-only semantic checker.

### Smallest useful experiment

Compare the current baseline with one minimal non-mutating variant using identical
cached OCR and candidate bytes:

```text
A: current main behaviour
B: immutable candidate + original check result; no semantic regex additions
```

Before B is allowed to alter accounting output, prove how failed claims are routed.
Do not merely stop deletion and let unsupported values flow silently.

Predeclare these minimum safety criteria before running the holdout:

- no newly removed or changed scan-correct claim;
- no increase in clean-invoice review flags;
- no reduction in wrong-candidate detection;
- no status improvement caused by deleting evidence;
- every accounting-output change traced to a human-adjudicated claim.

A change that misses any criterion is abandoned or narrowed before another run;
the holdout is not repeatedly tuned into a development set.

Required reporting:

- correct claims retained, changed, and removed;
- semantic wrong claims caught and escaped;
- OCR-origin errors reported separately;
- clean invoices newly flagged;
- purchase values changed after normalization;
- exact reason for every changed page;
- accountant-visible exception count.

Mandatory regression pages:

```text
page 1   adjacent table amounts
page 5   180- / 360- notation and omitted handwritten totals
page 10  globally poor source and B/8 identity ambiguity
page 20  row/summary extraction history
page 31  (-)0.13 notation
page 38  unaccounted confident OCR omission
page 52  (-)0.01 notation
```

A change does not continue merely because it fixes a unit probe. It must improve the
labelled corpus without creating new silent accounting mutations.

### Source-quality next step

The source-quality report is ready for more evidence, not production routing.

Possible next measurement:

1. complete labels for pages 41–57;
2. label at least one additional client's packet blind;
3. compare mean, P10, and under-70 share out of sample;
4. retain only metrics that add discrimination;
5. choose a threshold only after measuring false alarms on comfortable pages.

Do not add a model fallback, UI warning, or absolute threshold before that result.

### Operational cleanup

Credential rotation was not confirmed during this session. Confirm rotation of all
provider credentials exposed during live probes before running another probe. Do
not copy keys from session logs or temporary probe files into documentation,
fixtures, or Git.

## Rules for the next agent

- Do not resurrect Binder or add vendor labels to a deterministic verifier.
- Do not add Readiness or extraction-owned GSTR capability policy.
- Do not delete or overwrite model candidates based on heuristic evidence.
- Do not claim a detector improved accuracy without a labelled A/B against the
  current baseline.
- Do not treat a self-reported shadow status as evaluation truth.
- Do not duplicate `Purchase.Reconciliation` or `Workings`.
- Do not add production source-quality routing from the current in-sample pilot.
- Keep raw response bytes, model fingerprints, source pages, and provider failures.
- Keep `failure != unreadable` and `partial result != publishable`.
- Prefer deleting a failed experiment over protecting it with more tests.
