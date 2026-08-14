# Nila Docs

What's in here. Open the one that answers your question.

- [`prd.md`](./prd.md) — product intent: why Nila exists, who it's for, the GST wedge, goals and non-goals.
- [`architecture.md`](./architecture.md) — runtime, domain contexts, and the state principle.
- [`decisions.md`](./decisions.md) — system-level decisions and their reasoning (monolith, Postgres-as-truth, Oban, R2 storage, transactional code).
- [`ocr-extraction.md`](./ocr-extraction.md) — OCR/extraction provider behaviour: measured latency, why whole-packet extraction drops invoices past ~15 pages, and the chunking mandate. Extensible experiment log.
- [`verification-spike-retrospective.md`](./verification-spike-retrospective.md) — the 2026-08-14 verifier A/B, discarded Binder architecture, current production risk, lessons, and next-agent handoff.
- [`mistral-http-transport.md`](./mistral-http-transport.md) — the 2026-08-12 stale-connection investigation, retry semantics, discarded HTTP-client alternatives, and implemented document/chat transport split.
- [`design/DESIGN.md`](./design/DESIGN.md) — brand, principles, layout contracts, and the moonlight UI system.
- [`runbooks/`](./runbooks/) — debugging playbooks for shipped features.

Coding conventions live in [`../AGENTS.md`](../AGENTS.md). Claude-specific repo guidance in [`../CLAUDE.md`](../CLAUDE.md).

## Plans (`.plans/`, local-only, gitignored)

Implementation specs drafted after a grill, handed to an agent to build, then
**retained as the rationale record** — code shows *what* shipped, a plan explains
*why* it was built that way. They are not throwaway: a completed plan is the only
place the reasoning survives, so plans are never deleted on completion — their
`Status` flips instead.

Every plan opens with this header block, so the lifecycle is legible at a glance
without reading the body:

```
> **Status:** draft | handed-off | in-progress | shipped | proven | superseded | abandoned
> **Created / revised:** YYYY-MM-DD
> **Ships as:** <what it becomes in the codebase, or “scripts/ eval”>
> **Supersedes / superseded-by:** <plan filename, or —>
```

Status meanings: `draft` (pre-handoff), `handed-off` (given to an agent),
`in-progress` (partially built), `shipped` (in the product), `proven` (validated
against real data but not yet productionized), `superseded` (a newer plan replaced
it — kept for history), `abandoned` (dropped, kept so the dead end isn’t re-walked).

Body format is free — an eval plan and a milestone plan are genuinely different
shapes. Only the header is uniform. Plans are prefixed with their creation date
(`YYYY-MM-DD-name.md`) so they sort chronologically.
