# Tax-contract experiments

This runner compares sales-invoice extraction contracts. It does not change
production or post anything to Tally. The current scorer covers the reviewed
domestic taxable cases, not every GST treatment.

## Files

Reusable transformations, sending, replay and scoring live here. Reviewed case
facts belong in `eval/cases/`. Private PDF paths and their hashes stay in each
run's `inputs/sources.json`; PDFs are never copied into the repository.

Each run is `outputs/tax-contract/NNN-readable-name/`:

- `PLAN.md`: hypothesis, control, budget, rejection and promotion criteria.
- `inputs/`: source hashes, expectations, settings, exact prompts and schemas.
- `attempts/`: exact request, response, decoded data, replay and XLSX per call.
- `scores.json`, `summary.json`, `audit.json`, `REPORT.md`: checked results.

`grade.py`-style legacy runs use `grades.json`; the reusable scorer uses
`scores.json`. A run directory with attempts cannot be run again. Make a new
numbered directory even for a repeated experiment. Reports may be regenerated
from saved answers; do not edit the source expectations after inspecting model
answers unless documenting a verified transcription correction.

## Procedure

1. Inspect the source and record expected answers before model calls.
2. Freeze one hypothesis per candidate. Fix source inputs, grading, settings,
   repeats and call budget before starting. Three repeats are a consistency
   probe, not an accuracy guarantee.
3. Rotate arm order and run known failures first. Reject repeated serious
   regressions and any new wrong output that passes readiness.
4. Test survivors on broader cases, then untouched bills. A bill used to choose
   wording is no longer an untouched holdout.
5. Replay through the real application. Separate wrong-ready, wrong-held,
   correct-held and correct-ready outputs. Report model mistakes separately
   from application mistakes shared by every version.
6. Decide adopt, reject or inconclusive. Keep only supported improvements.
   Stop when the predeclared candidate budget ends; do not tweak until a pass.

## Run

Provide `inputs/sources.json`, `inputs/expectations.json`, `inputs/settings.json`
and `PLAN.md` in a fresh run directory. Sources follow the manifest in the first
run; settings name `arms`, `repeats` and `concurrency`.

```powershell
mix run --no-start eval/tax_contract/contract_test.exs
mix run --no-start eval/tax_contract/run.exs outputs/tax-contract/NEW-RUN
mix run --no-start eval/tax_contract/replay.exs outputs/tax-contract/NEW-RUN
python eval/tax_contract/score.py outputs/tax-contract/NEW-RUN
python eval/tax_contract/audit.py outputs/tax-contract/NEW-RUN
```

Scoring requires completed successful attempts; HTTP/schema failures must be
reported separately, not silently removed from the denominator. Reviewability
is the real `Workings.reviewable?/1` decision; this runner does not exercise the
download HTTP controller or Tally readiness. XLSX formula cells are read without
launching Excel. GST JSON checks cover the in-memory projection.

Production is the current source-code request, not a claim about the deployed
release. Keep source snapshots and hashes with each experiment.

To compare an application fix without overwriting original replay results:

```powershell
mix run --no-start eval/tax_contract/replay.exs ORIGINAL-RUN NEW-REPLAY-DIR
python eval/tax_contract/score.py ORIGINAL-RUN NEW-REPLAY-DIR
```

Frozen controls can use `settings.references`: map an arm name to an object
containing `run` and `arm`. The runner loads that saved prompt and schema while
keeping the current run's source parts. Reports use saved answers and scores;
regenerating a report makes no model calls.
