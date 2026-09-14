"""Summarize the saved speed-curve runs; never makes model calls."""
import json
import hashlib
import math
import statistics
import sys
from collections import Counter, defaultdict
from pathlib import Path

root = Path(sys.argv[1])
destination = Path(sys.argv[2])
read = lambda path: json.loads(path.read_text(encoding="utf-8"))
settings = read(root / "settings.json")
labels = {"qwen37": "Qwen 3.7 Flash", "qwen38": "Qwen 3.8 Flash", "luna": "Luna", "deepseek": "DeepSeek V4.1 Flash", "glm": "GLM 5.3 Flash"}
manifest = read(root / "manifest-all.json")["full"]
groups = defaultdict(list)
calls = defaultdict(list)
request_inputs = defaultdict(lambda: defaultdict(set))
all_runs = []
source_counts_path = root / "source-row-counts.json"
source_counts = {page["page"]: page["item_count"] for page in read(source_counts_path)["pages"]} if source_counts_path.exists() else {}
for path in sorted((root / "full").glob("*/summary.json")):
    run = read(path)
    # Pipeline artifacts already expand repeat_count through InvoiceRepairs.
    row_checks = []
    for item in run.get("invoice_counts", []):
        pages = item.get("source_pages", [])
        expected = sum(source_counts[page] for page in pages) if pages and all(page in source_counts for page in pages) else None
        row_checks.append({"pages": pages, "expected": expected, "actual": item["lines"], "missing_amount_lines": item.get("missing_amount_lines", []), "ok": expected is not None and item["lines"] == expected and item.get("monetary_lines") == item["lines"]})
    run["source_row_checks"] = row_checks
    run["coverage_ok"] = (run.get("outcome") == "ok" and bool(row_checks)
                          and run.get("groups_match") is True
                          and run.get("source_pages_covered") == list(range(1, run["pages"] + 1))
                          and run.get("unaccounted_pages") == []
                          and all(check["ok"] for check in row_checks))
    events = [json.loads(line) for line in (path.parent / "events.jsonl").read_text(encoding="utf-8").splitlines()]
    run["stages"] = {event["metadata"]["stage"]: event["duration_ms"] for event in events if event["event"] == "stage_completed"}
    groups[(run["model_alias"], run["pages"])].append(run)
    all_runs.append(run)
    for call_path in path.parent.glob("*-result.json"):
        call = read(call_path)
        call["run_id"] = run["run_id"]
        calls[run["model_alias"]].append(call)
        request_path = call_path.with_name(call_path.name.replace("-result.json", "-request.json"))
        request = read(request_path)
        call["source_pages"] = [int(part["text"].rsplit(" ", 1)[-1])
                                for message in request["messages"] if isinstance(message["content"], list)
                                for part in message["content"]
                                if part.get("type") == "text" and part["text"].startswith("PHYSICAL PAGE ")]
        shared_request = {key: value for key, value in request.items() if key not in ("model", "providerOptions", "reasoning")}
        fingerprint = hashlib.sha256(json.dumps(shared_request, sort_keys=True, ensure_ascii=False).encode("utf-8")).hexdigest()
        request_inputs[call["stage"]][fingerprint].add(run["model_alias"])
        if not call.get("local_schema_valid"):
            response_path = call_path.with_name(call_path.name.replace("-result.json", "-response.json"))
            try:
                response = read(response_path)
                content = (response.get("choices") or [{}])[0].get("message", {}).get("content", "")
            except (OSError, ValueError, AttributeError):
                content = ""
            call["markdown_fenced"] = isinstance(content, str) and content.lstrip().startswith("```")

run_key = lambda run: (run["model_alias"], run["pages"], run["repetition"])
expected_keys = {run_key(run) for run in manifest}
recorded_keys = {run_key(run) for run in all_runs}
if len(recorded_keys) != len(all_runs) or recorded_keys - expected_keys:
    raise ValueError("Duplicate or unexpected full runs; inspect the saved manifest.")
missing = [run for run in manifest if run_key(run) not in recorded_keys]
if "--final" in sys.argv[3:]:
    unavailable_path = root / "unavailable-models.json"
    unavailable = read(unavailable_path) if unavailable_path.exists() else {}
    unfinished = [run for run in missing if run["model_alias"] not in unavailable]
    if unfinished:
        raise ValueError(f"Cannot publish final report: {len(unfinished)} scheduled runs are missing.")
else:
    unavailable = {}

def seconds(value):
    return f"{value / 1000:.1f}"

def median(values):
    return seconds(statistics.median(values)) if values else "—"

def percentile(values, fraction):
    return sorted(values)[max(0, math.ceil(len(values) * fraction) - 1)] if values else None

complete_largest = []
for model in settings["models"]:
    runs = groups[(model["alias"], 15)]
    if len(runs) == 3 and all(run["coverage_ok"] for run in runs):
        complete_largest.append((statistics.median(run["duration_ms"] for run in runs), model["alias"]))

lines = [
    "# Sales extraction speed by model — 2026-09-14", "",
    f"Recorded {len(all_runs)} full packet runs of {len(manifest)} scheduled. Pilot runs are excluded from the curve.", "",
    "Same Breeze Tech PDF prefixes as the August 28 benchmark: 1, 4, 8 and 15 pages, expected to form 1, 3, 7 and 14 invoices. The one-page prefix cuts the first two-page invoice short. Three repetitions per model and size were scheduled.", "",
    "Runs use the current production vision pipeline: rendering, classification, concurrent invoice reading and artifact processing. Classification uses 75 DPI JPEG thumbnails at quality 70; invoice reading uses 200 DPI JPEG pages at quality 75. Evaluation-only HTTP handling supplies the current 14-field positional schema in the prompt and removes API response_format for every model. Local schema validation remains enabled. This is not the production default strict-output mode or the experimental two-amount contract.", "",
    "One packet run at a time; invoice fan-out concurrency 100 (at most 14 expected here). Temperature 0; no added output cap. Transient retries disabled; the existing one invalid-response retry remains and every attempt is recorded. Total time includes local preparation and instrumentation; individual HTTP times exclude writing the captured response. No database or deployment changes.", "",
    "The saved one-page Luna pilot returned 14 of 19 items. That omission remains part of the record even though pilots do not enter the timing curve.", "",
    "## Packet completion times", "",
    "Times below include returned runs even when coverage is incomplete; coverage flags must be read alongside speed. HTTP/pipeline errors are excluded from latency medians and counted in Returned. Coverage checks source page groups, item counts after repeat expansion, and whole-item amount presence, not financial accuracy. A unit price alone does not satisfy that amount check. Independent visual source totals are 19, 29, 37 and 46 items for the four prefixes.", "",
    "A missing whole-item amount does not by itself prove the final accounting value cannot be derived from other fields. The DeepSeek coverage failures are not a count of financially wrong invoices; this benchmark does not grade final workings.", "",
    "| Model | Pages | Returned / runs | Median total s | Range s | Complete-coverage median s | Classification s | Reading stage s | Coverage passed |",
    "|---|---:|---:|---:|---:|---:|---:|---:|---:|",
]
if complete_largest:
    duration, alias = min(complete_largest)
    lines[2:2] = [f"{labels[alias]} was fastest among models that returned the expected number of rows, each with a whole-item amount, in all three 15-page runs: median {seconds(duration)} seconds. This establishes speed on this packet, not correctness of every extracted value or row identity.", ""]
attempts = [call for entries in calls.values() for call in entries]
valid_attempts = sum(call.get("local_schema_valid") is True and call.get("finish_reason") == "stop" for call in attempts)
lines[lines.index("## Packet completion times"):lines.index("## Packet completion times")] = [f"The full runs made {len(attempts)} HTTP calls, including classification: {valid_attempts}/{len(attempts)} finished with locally schema-valid JSON. A valid response can still omit or misread values.", ""]
for model in settings["models"]:
    alias = model["alias"]
    for pages in [1, 4, 8, 15]:
        runs = groups[(alias, pages)]
        ok = [run for run in runs if run["outcome"] == "ok"]
        times = [run["duration_ms"] for run in ok]
        span = f"{seconds(min(times))}–{seconds(max(times))}" if times else "—"
        stage = lambda name: median([run["stages"][name] for run in ok if name in run["stages"]])
        complete = median([run["duration_ms"] for run in runs if run.get("coverage_ok") is True])
        lines.append(f"| {alias} | {pages} | {len(ok)}/{len(runs)} | {median(times)} | {span} | {complete} | {stage('vision_segmentation')} | {stage('vision_extraction')} | {sum(run.get('coverage_ok') is True for run in runs)}/{len(runs)} |")

if missing:
    lines += ["", "## Unrecorded runs", ""]
    for model in settings["models"]:
        alias = model["alias"]
        count = sum(run["model_alias"] == alias for run in missing)
        if count:
            explanation = unavailable.get(alias, "Pending; this report is preliminary.")
            lines.append(f"- {alias}: {count} scheduled runs unrecorded. {explanation}")

incomplete = [run for run in all_runs if not run["coverage_ok"]]
if incomplete:
    lines += ["", "## Failed or incomplete packet runs", ""]
    for run in incomplete:
        reasons = []
        if run.get("outcome") != "ok":
            reasons.append(f"pipeline outcome {run.get('outcome')}")
        if run.get("groups_match") is False:
            reasons.append("invoice page groups differ")
        for check in run["source_row_checks"]:
            if check["actual"] != check["expected"]:
                reasons.append(f"pages {check['pages']}: {check['actual']} items, expected {check['expected']}")
            if check["missing_amount_lines"]:
                reasons.append(f"pages {check['pages']}: {len(check['missing_amount_lines'])} items without an extended amount")
        lines.append(f"- `{run['run_id']}` ({seconds(run['duration_ms'])} s): {'; '.join(reasons) or 'source coverage incomplete'}.")

lines += ["", "## Individual invoice calls and the slow tail", "",
          "HTTP 200 invoice calls with finish_reason=stop, including answers rejected by the local parser or schema. Retries are separate calls here and remain inside packet time above. Calls can still contain missing or wrong items. Repeated invoices and packet sizes are pooled, so p95 describes this workload rather than arbitrary customer invoices. Nearest-rank p95 is descriptive.", "",
          "| Model | Calls | Schema-valid | Mean s | Median s | p95 s | Slowest s |",
          "|---|---:|---:|---:|---:|---:|---:|"]
usage_rows = []
slowest_sources = []
for model in settings["models"]:
    alias = model["alias"]
    entries = calls[alias]
    completed_calls = [call for call in entries if call["stage"] == "extraction" and call.get("http_status") == 200 and call.get("finish_reason") == "stop"]
    times = [call["duration_ms"] for call in completed_calls]
    if completed_calls:
        slowest_sources.append(max(completed_calls, key=lambda call: call["duration_ms"])["source_pages"])
    reasoning = sum(((call.get("usage") or {}).get("completion_tokens_details") or {}).get("reasoning_tokens", 0) or 0 for call in entries)
    cost = sum((call.get("usage") or {}).get("cost", 0) or 0 for call in entries)
    p95 = seconds(percentile(times, .95)) if times else "—"
    slow = seconds(max(times)) if times else "—"
    mean = seconds(statistics.mean(times)) if times else "—"
    valid_count = sum(call.get("local_schema_valid") is True for call in completed_calls)
    lines.append(f"| {alias} | {len(times)} | {valid_count} | {mean} | {median(times)} | {p95} | {slow} |")
    cost_text = f"{cost:.8f}" if entries else "—"
    reasoning_text = str(reasoning) if entries else "—"
    usage_rows.append(f"| {alias} | {len(entries)} | {reasoning_text} | {cost_text} |")

lines += ["", "p95 means 95% of these calls finished within that time. A packet waits for its slowest invoice call, because invoice calls run together.", "",
          "| Model | All-stage HTTP attempts | Reasoning tokens | Reported cost |",
          "|---|---:|---:|---:|"] + usage_rows
if slowest_sources and all(pages == [1, 2] for pages in slowest_sources):
    lines += ["", "For every measured model, its slowest invoice call was the same 27-item invoice on pages 1–2. The slow tail here includes a larger extraction task, not merely variable provider delay."]

fenced_failures = Counter(call["requested_model"] for call in attempts if call.get("markdown_fenced"))
if fenced_failures:
    lines += ["", "## Output-format failures", ""]
    for model, count in sorted(fenced_failures.items()):
        lines.append(f"- `{model}`: {count} rejected HTTP answers began with Markdown code fences.")
    lines += ["", "The current production parser expects bare JSON and does not remove these fences. No parser or prompt change was made during the benchmark. Recovered retries can still pass the final coverage check; a packet that exhausts its retry returns an error. These are formatting failures, not evidence by themselves that the invoice amounts were wrong."]

lines += ["", "## Settings and interpretation", "",
          "Qwen 3.7/3.8 are pinned to Alibaba with thinking disabled. Luna is pinned to OpenAI with reasoning none. DeepSeek is pinned to DeepSeek with thinking disabled. GLM is pinned to Z.AI; its endpoint rejected thinking disabled, so the replacement configuration requests reasoning low. This is a comparison of usable configurations, not identical reasoning settings. Requested settings are not a guarantee; reported reasoning is shown above.", "",
          "GLM returned HTTP 429 at capacity on its first two low-reasoning probes. The final probe succeeded, so its twelve scheduled runs ran after the other four models. The four-model runs were interleaved; GLM was measured in a later service window. Its one-page successful pilot took 66.6 seconds and reported 1,060 reasoning tokens. All pilots, including capacity failures, are excluded from the full-run timing tables.", "",
          "Cost is the sum of response usage.cost; the response metadata does not name its currency. Cache behavior varies.", "",
          "The August report recorded median total times of 32.8, 38.7, 53.1 and 49.4 seconds for these four sizes. Source PDFs match, but code, prompt, output mode and upstream service conditions differ; this is not a model-only before/after comparison.", "",
          "## Reproduce and inspect", "",
          f"Raw artifacts: `{root.as_posix()}`. Each run saves source hashes, exact sent payloads, response bodies and headers, per-call timings, stage events, returned artifacts and summary flags. No API keys are written. Pilot and rejected settings are kept separately from full runs.", "",
          "To rerun, use a fresh output directory. Copy settings.json, source-row-counts.json and manifest-all.json there, and also copy manifest-all.json as manifest.json. The manifest points to the four source PDFs and records their hashes. Run `mix run --no-start eval/benchmarks/sales_extraction_models.exs full OUTPUT_DIR`. Existing run directories are protected from overwrite; the saved execution-manifests directory records the original staged execution.", "",
          "Regenerate this report from the saved results with `python eval/benchmarks/sales_extraction_models_report.py OUTPUT_DIR REPORT_PATH --final`. Final generation checks the frozen schedule: each available model must have all three runs at each size. Any skipped model needs a recorded reason in unavailable-models.json. request-equivalence.json records hashes of the requests after removing only model, provider and reasoning controls.", "",
          "Model references: [GLM 5.3 Flash](https://vercel.com/ai-gateway/models/glm-5.3-flash), [DeepSeek V4.1 Flash](https://vercel.com/changelog/deepseek-v4-1-flash-now-available-on-ai-gateway).", ""]
input_audit = {stage: {key: sorted(models) for key, models in variants.items()} for stage, variants in request_inputs.items()}
measured_models = {run["model_alias"] for run in all_runs}
if request_inputs and all(models == measured_models for variants in request_inputs.values() for models in variants.values()):
    section = lines.index("## Reproduce and inspect")
    lines[section:section] = [f"Captured request hashes confirm the same images, instructions, schema and temperature across all {len(measured_models)} measured models, after removing only model, provider and reasoning settings. There are {len(request_inputs['classification'])} distinct classification inputs and {len(request_inputs['extraction'])} invoice inputs.", ""]
(root / "request-equivalence.json").write_text(json.dumps(input_audit, indent=2), encoding="utf-8")
destination.write_text("\n".join(lines), encoding="utf-8")
(root / "aggregate.json").write_text(json.dumps({"runs": all_runs, "calls": calls}, indent=2), encoding="utf-8")
print(f"Summarized {len(all_runs)} full runs into {destination}")
