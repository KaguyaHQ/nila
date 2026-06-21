# Nila — Product Requirements

> "AI labor for the compliance back office."

_Intent doc. Last reviewed 2026-06-21._

This is **why Nila exists, who it is for, and what we will and won't build** — product
intent, not a snapshot of the code. Current state lives in the code, git history, and
`docs/.plans/`. This file should change when the *product* changes, not when code ships.
If it contradicts the code, the code is right and this needs a review.

> **History.** Nila began as a system-of-record for a family field-service business. That
> thesis is archived intact in the `nila-ops` repo. The product pivoted to a **CA AI-labor
> engine**; `docs/CA_PIVOT_PLAN.md` records the repo-extraction decision and
> `docs/STRATEGY.md` the reasoning. Some interior docs (`architecture.md`, `discovery/`,
> `AGENT_MAP.md`) still describe the archived ops thesis and are pending a CA rewrite.

---

## 1. Problem & users

Indian Chartered Accountant (CA) firms sell their clients' compliance work — bookkeeping,
GST returns, reconciliations. The work itself is high-volume, repetitive cognition done by
junior staff: reading a bank statement line by line and assigning each transaction to a
ledger account; matching purchase invoices against the GSTR-2B the GST portal returns;
chasing the mismatches. It is exactly the unstructured→structured translation that has
historically required a human clerk.

**First user.** A CA firm's partner who carries the cost of that junior labor and signs
behind its output. We build and validate the engine on the family business's own consented
books first (ground truth in hand), then against CA Excel from the discovery sprint. We do
**not** extract raw client data from CA firms to start.

**The pain.**

- **Junior-staff time is the cost.** Classification and reconciliation are the bulk of the
  hours a firm spends per client, and they scale linearly with client count.
- **Errors are stochastic and costly.** A misclassified transaction or a missed GSTR-2B
  mismatch surfaces late, as a notice or a wrong return.
- **The work doesn't compound.** Every month's statements are re-read from scratch; nothing
  the firm learns about a client's patterns is captured as leverage.

## 2. What Nila is

An **AI-labor engine** for the CA back office. The unit of work: produce a first-pass
structured result, route the uncertain ones to a human, keep an audit trail. Five stages:

1. **Ingest** — bank statement / PDF in (reuses `documents` + the extractor + email/whatsapp
   intake).
2. **Classify** — each transaction → ledger category, emitting a **confidence per line**.
3. **Route (calibration)** — high-confidence auto-applied; low-confidence → a review queue.
   This is the trust bar, and the human-in-the-loop is the product, not a fallback.
4. **Reconcile** — GSTR-2B match (needs supplier-filing data we don't yet have; second act).
5. **Output** — a draft return / structured ledger the CA reviews and signs.

## 3. Non-goals

- Not a full accounting suite or a Tally replacement.
- Not removing the CA's judgment or statutory sign-off — **Nila drafts, the CA signs.**
- Not autonomous: low-confidence always routes to a human.
- Not (yet) ingesting client data directly from CA firms — prove the engine on consented
  data first.

## 4. The trust bar

Value is the **fraction of lines auto-cleared at an accuracy the CA will sign behind.** A
classifier that is right 99% of the time but can't say *which* 99% is worthless here; one
that is right 80% of the time and *knows it* is valuable, because the 80% clears and the 20%
routes. Calibration — honest confidence — is the metric that matters, not raw accuracy.

## 5. What's built (substrate)

The portable substrate carried from `nila-ops`: auth + tenancy (orgs / entities /
memberships), the document→structured **extractor** (the crown jewel), GST jurisdiction
logic, the audit log, a pluggable storage behaviour, an Oban-backed workflow step-runner,
email/whatsapp ingestion, and the assistant. The CA engine (classify / route / reconcile)
and its review-unit (the rebuilt approvals/HITL schema) are built on top.
