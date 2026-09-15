# Nila Docs

Start with the current product and code map, then open a focused guide.

- [Product objective](prd.md) — the job we are solving, customer evidence, and what is still unproven.
- [Architecture](architecture.md) — how the app fits together.
- [Sales code guide](../lib/nila/gst/sales/README.md) — invoice facts, review, and workings ownership.
- [Extraction code guide](../lib/nila/gst/extraction/README.md) — document reading and its boundary with sales facts.
- [Model cost baseline](cost/model-costs.md) — dated production usage, token, and inference-cost measurements.
- [Decisions](decisions.md) — why we use this structure, including transactions and storage.
- [Design guide](design/DESIGN.md) — start here for UI work; it routes to the detailed guides.
- [Demo script](demo-script.md) and [runbook](demo-runbook.md) — presentation flow and dated rehearsal details.

Coding conventions live in [AGENTS.md](../AGENTS.md).

## Archive

Historical evidence and superseded directions, not current implementation instructions:

- [`archive/demo-prd.md`](./archive/demo-prd.md) — earlier bills-to-Tally demo.
- [`archive/ocr-extraction.md`](./archive/ocr-extraction.md) — experiments and findings from the retired OCR path.
- [`archive/verification-spike-retrospective.md`](./archive/verification-spike-retrospective.md) — retired verifier experiment and source-quality findings.
- [`archive/mistral-http-transport.md`](./archive/mistral-http-transport.md) — retired Mistral transport investigation and retry lessons.
- [`archive/prd-history.md`](./archive/prd-history.md) — superseded product strategy and hypotheses.
- [`archive/decisions-history.md`](./archive/decisions-history.md) — earlier infrastructure reasoning and retired designs.

## Local plans

`.plans/` is a local, gitignored workspace for implementation notes. Durable system
decisions belong in `decisions.md`; retired directions belong in `archive/`.
