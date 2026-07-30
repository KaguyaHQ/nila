# OCR probes

Reusable harnesses that characterise real Mistral OCR behaviour against GST packets.
Findings and evidence tables live in [`docs/ocr-extraction.md`](../../docs/ocr-extraction.md);
these scripts reproduce them. The API is a sandbox (not billed), so rerun freely.

Run with the Mistral key configured (dev sources `.env`):

```bash
MIX_ENV=dev mix run scripts/ocr_probes/<probe>.exs
```

| Probe                     | Question it answers                                          | Rerun when …                                              |
|---------------------------|-------------------------------------------------------------|----------------------------------------------------------|
| `omission.exs`            | Does whole-PDF extraction match the filed R1 invoice set?   | prompt/schema/provider changes — recall regression guard |
| `whole_packet_canary.exs` | Does the windowed path recover RAC2451 (p51) from the 57-page packet? | changing window size/overlap, dedupe, or the ledger |
| `cold_latency_curve.exs`  | Cold latency vs. page count (the ~3.5s/page budget)?        | changing chunk size, model version, or provider           |

Notes:
- All probes read packets from the private eval corpus (`eval/corpus.json` →
  R2 bucket `nila-eval-corpus`). First run: `mix nila.eval_corpus pull` — needs
  the eval-scoped token in `.env`. Ground-truth `returns_*_R1_*.json` files stay
  committed under `test/fixtures/`.
- `omission.exs` runs every sales corpus document that has filed-R1 ground truth
  and diffs extracted invoice numbers against it.
- The canary defaults to the windowed path; pass `whole` to reproduce the
  single-call failure it was written for.
- Raw responses are written under `tmp/mistral_*_probe/` for inspection.
