# Extraction wording check — 2026-09-05

Live production extraction used `alibaba/qwen3.7-flash` through
`vercel-ai-gateway` on the January (8 pages), February (6 pages) and March
(12 pages) packets. The extraction schema no longer requests
`original_sale_category`. Existing `review.json` corrections were replayed
unchanged; no HSN correction was added to make these runs pass.

| Wording | January score | February score | March score |
| --- | ---: | ---: | ---: |
| Short schema only | 92.52 | 86.49 | 95.83 |
| Short schema + prompt reminder | 92.52 | 86.49 | 95.83 |
| Short schema + reminder + example (retained) | 98.02 | 96.83 | 95.83 |

The first two variants missed SAC 998719 on NW-DN-001 and NU-DN-S,
leaving missing-HSN review issues and HSN financial differences. The retained
variant includes the short example `Consulting - 998312 @ 18%` to illustrate
an embedded SAC. All 26 documents were accounted for. After existing review
corrections, the retained variant has no remaining issues or silent errors;
only HSN `desc`/`user_desc` text differs from the native returns. Financial
amounts, reporting classifications and document summaries match.

This is one live run per packet per variant, not a statistical reliability
claim. Historical fixture extractions remain unchanged. Automated tests replay
those captures; they do not invoke the model.

## Private evidence

Bucket: `nila-eval-corpus`. Each run is under
`tally/caltech/<month>/runs/<run>/`, with `manifest.json`, `extraction.json`,
`diff.json`, `workings.json`, `reviewed-diff.json`, `reviewed-workings.json`
and `reviewed-resolutions.json`. The manifest identifies the model and source
PDF/native-return hashes. Uploads were read back and checked byte-for-byte.

| Variant | Month | Run |
| --- | --- | --- |
| Schema only | 2026-01 | 2026-09-05T06-20-18.098000Z |
| Schema only | 2026-02 | 2026-09-05T06-20-38.720000Z |
| Schema only | 2026-03 | 2026-09-05T06-20-38.983000Z |
| Reminder | 2026-01 | 2026-09-05T06-21-34.636000Z |
| Reminder | 2026-02 | 2026-09-05T06-21-34.822000Z |
| Reminder | 2026-03 | 2026-09-05T06-21-35.221000Z |
| Reminder + example | 2026-01 | 2026-09-05T06-22-43.217000Z |
| Reminder + example | 2026-02 | 2026-09-05T06-22-43.381000Z |
| Reminder + example | 2026-03 | 2026-09-05T06-22-43.500000Z |
