# Sales extraction evaluations

Keep repeatable experiments here; keep raw runs and one-off probes in
`tmp/<date>/invoice-extraction/`. Do not copy the PDFs from the evaluation corpus.

## What is shared

- `support/requests.exs` sends prepared requests and records attempts: exact JSON,
  response, schema, response headers (without cookies), local validity, usage and
  timing. It does not select the model, change a schema or retry. Experiment scripts
  own those decisions. Existing attempt prefixes cannot be overwritten.
- `support/sales_replay.exs` replays saved answers through current repairs and sales
  normalization without model calls. Its directory runner preserves the historical
  June manifest/field-order conventions; it is not a generic manifest parser.
  Other experiments can call `replay(data, fields, contract, client_gstin, source_pages)`
  with `:legacy` or `:two_amount`, keeping their own manifest and client identity.
- `support/sales_scoring.py` preserves the June financial and identity checks.
  `cases/simple_systems_june_2026.json` holds the reviewed expected answers. The
  scorer assumes this corpus's tax structure; it is not a general GST validator.

## Run the app pipeline

```powershell
mix run --no-start eval/benchmarks/sales_extraction_models.exs full RUN_DIR
python eval/benchmarks/sales_extraction_models_report.py RUN_DIR REPORT.md --final
```

The run directory supplies `settings.json` (models/provider options), `manifest.json`
(sources, SHA-256 hashes, page groups, repeats and run order), `manifest-all.json`
(the complete `full` schedule), and `source-row-counts.json` (reviewed page counts).
Use a fresh directory for new calls. The September 14 run under
`tmp/2026-09-14/invoice-extraction/model-speed-curve` is an example of these explicit
inputs; the runner does not embed its source paths or credentials.

This particular benchmark uses the app's full classification/extraction pipeline,
but **explicitly fixes vision input and the original amount contract**. Its HTTP
adapter puts the schema in the prompt and disables API schema enforcement for all
models. Local validation stays on. It therefore does not measure the new local
table route or unmodified production HTTP settings. Its report measures completeness,
latency and cost, not full financial correctness. Keep those boundaries in reports.

For an invoice-only experiment, use the app's `Pipeline.extract_fixed_segments/4`
and `InvoiceRequest.build/4` when possible. A provider-compatibility probe may instead
call `Nila.Eval.Requests.post/1` inside `capture/5` with a deliberately prepared
request. Keep that experiment separate from full-pipeline accuracy claims.

## Replay and score saved June answers (no model calls)

```powershell
mix run --no-start eval/benchmarks/replay_june_sales.exs SAVED_RUN REPLAY_DIR
python eval/support/sales_scoring.py SAVED_RUN --accounting-dir REPLAY_DIR --expected eval/cases/simple_systems_june_2026.json --output NEW_SCORES.json
```

The replay command writes to a separate directory so historical accounting is not
replaced. `--accounting-dir` scores those new results against the saved model answers.
Without it, the scorer reads accounting beside the saved data. The Python APIs
`score_run(result, accounting, expected_case)` and
`score_directory(directory, expected=None, accounting_dir=None)` do not write files.
The old temporary wrappers still work, including their original in-place output
defaults; use separate destinations when comparing code versions.

Report HTTP success, local schema validity, checked financial fields and completeness
separately. Cost should include retries and classification when applicable, and show
cached/reasoning tokens. Do not invent unlabelled financial ground truth for a speed
corpus. New vendors need their own reviewed cases and applicable scoring rules.

## Cleanup verification

```powershell
mix run --no-start --no-compile eval/support/requests_test.exs
```

This uses fake responses, not the network. Saved-answer parity evidence for the
consolidation is under `tmp/2026-09-14/eval-cleanup/`: replay, score and capture
comparisons. The diagnostic probes and their historic requests/responses stay in
their original temporary locations; they need not become permanent benchmark code.
