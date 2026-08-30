# Sales extraction latency curve — 2026-08-28

Production vision pipeline benchmark using prefixes of the same Breeze Tech sales PDF.
Each size ran three times in an interleaved order against the configured production
provider and model. The first document spans two pages, so the controlled inputs contain
1, 3, 7 and 14 discovered invoices across 1, 4, 8 and 15 pages respectively.

| Pages | Invoices | Median total | Range | Median segmentation | Median reading |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 1 | 32.8 s | 31.1–36.7 s | 3.2 s | 29.5 s |
| 4 | 3 | 38.7 s | 36.3–39.0 s | 5.7 s | 31.1 s |
| 8 | 7 | 53.1 s | 52.0–54.1 s | 9.9 s | 42.1 s |
| 15 | 14 | 49.4 s | 48.2–64.4 s | 12.4 s | 37.2 s |

Segmentation cost grows with page count. Invoice extraction fans out concurrently, so
batch completion is governed by the slowest invoice call rather than the sum of invoice
durations. Larger batches therefore increase tail risk without producing a linear
per-invoice curve.

Each extraction run writes `tmp/sales-extraction-curve.jsonl` with every stage
transition, provider-call duration and completion record. Run the benchmark with:

    mix run --no-start eval/benchmarks/sales_extraction_curve.exs extract PDF [PDF ...]

Query persisted production extraction attempts with:

    mix run --no-start eval/benchmarks/sales_extraction_curve.exs history
