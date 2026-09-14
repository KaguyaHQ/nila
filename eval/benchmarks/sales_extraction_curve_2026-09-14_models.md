# Sales extraction speed by model — 2026-09-14

Luna was fastest among models that returned the expected number of rows, each with a whole-item amount, in all three 15-page runs: median 25.7 seconds. This establishes speed on this packet, not correctness of every extracted value or row identity.

Recorded 60 full packet runs of 60 scheduled. Pilot runs are excluded from the curve.

Same Breeze Tech PDF prefixes as the August 28 benchmark: 1, 4, 8 and 15 pages, expected to form 1, 3, 7 and 14 invoices. The one-page prefix cuts the first two-page invoice short. Three repetitions per model and size were scheduled.

Runs use the current production vision pipeline: rendering, classification, concurrent invoice reading and artifact processing. Classification uses 75 DPI JPEG thumbnails at quality 70; invoice reading uses 200 DPI JPEG pages at quality 75. Evaluation-only HTTP handling supplies the current 14-field positional schema in the prompt and removes API response_format for every model. Local schema validation remains enabled. This is not the production default strict-output mode or the experimental two-amount contract.

One packet run at a time; invoice fan-out concurrency 100 (at most 14 expected here). Temperature 0; no added output cap. Transient retries disabled; the existing one invalid-response retry remains and every attempt is recorded. Total time includes local preparation and instrumentation; individual HTTP times exclude writing the captured response. No database or deployment changes.

The saved one-page Luna pilot returned 14 of 19 items. That omission remains part of the record even though pilots do not enter the timing curve.

The full runs made 458 HTTP calls, including classification: 429/458 finished with locally schema-valid JSON. A valid response can still omit or misread values.

## Packet completion times

Times below include returned runs even when coverage is incomplete; coverage flags must be read alongside speed. HTTP/pipeline errors are excluded from latency medians and counted in Returned. Coverage checks source page groups, item counts after repeat expansion, and whole-item amount presence, not financial accuracy. A unit price alone does not satisfy that amount check. Independent visual source totals are 19, 29, 37 and 46 items for the four prefixes.

A missing whole-item amount does not by itself prove the final accounting value cannot be derived from other fields. The DeepSeek coverage failures are not a count of financially wrong invoices; this benchmark does not grade final workings.

| Model | Pages | Returned / runs | Median total s | Range s | Complete-coverage median s | Classification s | Reading stage s | Coverage passed |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| qwen37 | 1 | 3/3 | 32.6 | 29.1–36.2 | 32.6 | 2.9 | 29.4 | 3/3 |
| qwen37 | 4 | 3/3 | 51.3 | 43.4–63.9 | 51.3 | 6.7 | 43.3 | 3/3 |
| qwen37 | 8 | 3/3 | 59.7 | 55.8–65.7 | 59.7 | 10.9 | 47.0 | 3/3 |
| qwen37 | 15 | 3/3 | 62.7 | 61.2–63.8 | 62.7 | 16.4 | 44.8 | 3/3 |
| qwen38 | 1 | 3/3 | 56.0 | 51.1–56.2 | 56.0 | 4.7 | 51.2 | 3/3 |
| qwen38 | 4 | 3/3 | 61.7 | 49.2–91.2 | 61.7 | 8.6 | 52.6 | 3/3 |
| qwen38 | 8 | 3/3 | 63.8 | 56.7–69.8 | 63.8 | 11.3 | 51.7 | 3/3 |
| qwen38 | 15 | 3/3 | 75.1 | 66.3–79.2 | 75.1 | 22.9 | 54.7 | 3/3 |
| luna | 1 | 3/3 | 16.4 | 14.1–17.2 | 16.4 | 2.4 | 13.9 | 3/3 |
| luna | 4 | 3/3 | 21.7 | 20.0–22.2 | 21.7 | 2.8 | 17.9 | 3/3 |
| luna | 8 | 3/3 | 24.6 | 23.9–24.6 | 24.6 | 4.3 | 18.9 | 3/3 |
| luna | 15 | 3/3 | 25.7 | 24.9–26.1 | 25.7 | 6.0 | 18.3 | 3/3 |
| deepseek | 1 | 3/3 | 9.9 | 9.4–9.9 | 9.9 | 2.3 | 7.1 | 1/3 |
| deepseek | 4 | 3/3 | 12.4 | 11.9–13.2 | 12.4 | 2.7 | 9.5 | 1/3 |
| deepseek | 8 | 3/3 | 13.6 | 13.2–14.1 | — | 3.4 | 9.1 | 0/3 |
| deepseek | 15 | 3/3 | 15.8 | 15.3–15.9 | — | 4.7 | 9.8 | 0/3 |
| glm | 1 | 3/3 | 73.1 | 54.4–122.2 | 73.1 | 7.9 | 63.3 | 3/3 |
| glm | 4 | 2/3 | 93.3 | 90.2–96.3 | 93.3 | 10.9 | 81.9 | 2/3 |
| glm | 8 | 2/3 | 87.4 | 87.2–87.7 | 87.4 | 10.6 | 76.0 | 2/3 |
| glm | 15 | 0/3 | — | — | — | — | — | 0/3 |

## Failed or incomplete packet runs

- `07-deepseek-15p-r1` (15.3 s): pages [1, 2]: 27 items without an extended amount.
- `09-glm-15p-r1` (180.2 s): pipeline outcome error.
- `13-deepseek-8p-r1` (14.1 s): pages [1, 2]: 27 items without an extended amount.
- `17-deepseek-1p-r1` (9.9 s): pages [1]: 19 items without an extended amount.
- `22-glm-15p-r2` (158.6 s): pipeline outcome error.
- `26-deepseek-15p-r2` (15.9 s): pages [1, 2]: 27 items without an extended amount.
- `27-deepseek-8p-r2` (13.6 s): pages [1, 2]: 27 items without an extended amount.
- `35-deepseek-4p-r2` (11.9 s): pages [1, 2]: 27 items without an extended amount.
- `38-deepseek-1p-r2` (9.4 s): pages [1]: 19 items without an extended amount.
- `46-deepseek-8p-r3` (13.2 s): pages [1, 2]: 27 items without an extended amount.
- `49-glm-4p-r3` (174.9 s): pipeline outcome error.
- `51-glm-8p-r3` (178.0 s): pipeline outcome error.
- `53-glm-15p-r3` (90.8 s): pipeline outcome error.
- `55-deepseek-15p-r3` (15.8 s): pages [1, 2]: 27 items without an extended amount.
- `58-deepseek-4p-r3` (13.2 s): pages [1, 2]: 27 items without an extended amount.

## Individual invoice calls and the slow tail

HTTP 200 invoice calls with finish_reason=stop, including answers rejected by the local parser or schema. Retries are separate calls here and remain inside packet time above. Calls can still contain missing or wrong items. Repeated invoices and packet sizes are pooled, so p95 describes this workload rather than arbitrary customer invoices. Nearest-rank p95 is descriptive.

| Model | Calls | Schema-valid | Mean s | Median s | p95 s | Slowest s |
|---|---:|---:|---:|---:|---:|---:|
| qwen37 | 75 | 75 | 15.2 | 10.1 | 46.9 | 58.1 |
| qwen38 | 75 | 75 | 20.7 | 14.7 | 54.6 | 82.1 |
| luna | 75 | 75 | 7.1 | 5.0 | 18.7 | 19.5 |
| deepseek | 75 | 75 | 4.9 | 4.3 | 9.7 | 10.4 |
| glm | 98 | 69 | 24.6 | 14.8 | 83.7 | 90.4 |

p95 means 95% of these calls finished within that time. A packet waits for its slowest invoice call, because invoice calls run together.

| Model | All-stage HTTP attempts | Reasoning tokens | Reported cost |
|---|---:|---:|---:|
| qwen37 | 87 | 0 | 0.03023207 |
| qwen38 | 87 | 0 | 0.08806490 |
| luna | 87 | 0 | 0.11277284 |
| deepseek | 87 | 0 | 0.09155789 |
| glm | 110 | 21157 | 0.17873960 |

For every measured model, its slowest invoice call was the same 27-item invoice on pages 1–2. The slow tail here includes a larger extraction task, not merely variable provider delay.

## Output-format failures

- `zai/glm-5.3-flash`: 29 rejected HTTP answers began with Markdown code fences.

The current production parser expects bare JSON and does not remove these fences. No parser or prompt change was made during the benchmark. Recovered retries can still pass the final coverage check; a packet that exhausts its retry returns an error. These are formatting failures, not evidence by themselves that the invoice amounts were wrong.

## Settings and interpretation

Qwen 3.7/3.8 are pinned to Alibaba with thinking disabled. Luna is pinned to OpenAI with reasoning none. DeepSeek is pinned to DeepSeek with thinking disabled. GLM is pinned to Z.AI; its endpoint rejected thinking disabled, so the replacement configuration requests reasoning low. This is a comparison of usable configurations, not identical reasoning settings. Requested settings are not a guarantee; reported reasoning is shown above.

GLM returned HTTP 429 at capacity on its first two low-reasoning probes. The final probe succeeded, so its twelve scheduled runs ran after the other four models. The four-model runs were interleaved; GLM was measured in a later service window. Its one-page successful pilot took 66.6 seconds and reported 1,060 reasoning tokens. All pilots, including capacity failures, are excluded from the full-run timing tables.

Cost is the sum of response usage.cost; the response metadata does not name its currency. Cache behavior varies.

The August report recorded median total times of 32.8, 38.7, 53.1 and 49.4 seconds for these four sizes. Source PDFs match, but code, prompt, output mode and upstream service conditions differ; this is not a model-only before/after comparison.

Captured request hashes confirm the same images, instructions, schema and temperature across all 5 measured models, after removing only model, provider and reasoning settings. There are 4 distinct classification inputs and 15 invoice inputs.

## Reproduce and inspect

Raw artifacts: `tmp/2026-09-14/invoice-extraction/model-speed-curve`. Each run saves source hashes, exact sent payloads, response bodies and headers, per-call timings, stage events, returned artifacts and summary flags. No API keys are written. Pilot and rejected settings are kept separately from full runs.

To rerun, use a fresh output directory. Copy settings.json, source-row-counts.json and manifest-all.json there, and also copy manifest-all.json as manifest.json. The manifest points to the four source PDFs and records their hashes. Run `mix run --no-start eval/benchmarks/sales_extraction_models.exs full OUTPUT_DIR`. Existing run directories are protected from overwrite; the saved execution-manifests directory records the original staged execution.

Regenerate this report from the saved results with `python eval/benchmarks/sales_extraction_models_report.py OUTPUT_DIR REPORT_PATH --final`. Final generation checks the frozen schedule: each available model must have all three runs at each size. Any skipped model needs a recorded reason in unavailable-models.json. request-equivalence.json records hashes of the requests after removing only model, provider and reasoning controls.

Model references: [GLM 5.3 Flash](https://vercel.com/ai-gateway/models/glm-5.3-flash), [DeepSeek V4.1 Flash](https://vercel.com/changelog/deepseek-v4-1-flash-now-available-on-ai-gateway).
