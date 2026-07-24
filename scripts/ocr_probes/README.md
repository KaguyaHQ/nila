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
| `whole_packet_canary.exs` | Does the 57-page packet still drop invoices (RAC2451, p51)? | testing the chunker — must recover the dropped invoice    |
| `cold_latency_curve.exs`  | Cold latency vs. page count (the ~3.5s/page budget)?        | changing chunk size, model version, or provider           |

Notes:
- `omission.exs` reads sales fixtures under `test/fixtures/gstr1/` and diffs against
  the `returns_*_R1_*.json` ground truth — self-contained in the repo.
- `whole_packet_canary.exs` and `cold_latency_curve.exs` point at local demo PDFs
  under `~/Documents/data/demo/` (not committed). Repoint the paths to any large
  packet to reproduce.
- Raw responses are written under `tmp/mistral_*_probe/` for inspection.
