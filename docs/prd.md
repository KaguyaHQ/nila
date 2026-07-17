# Nila — Product Requirements

> "The AI accountant."

_Intent doc. Last reviewed 2026-07-24._

This is **why Nila exists, who it is for, and what we will and won't build** — product
intent, not a snapshot of the code. Current state lives in the code and git history. This
file should change when the *product* changes, not when code ships. If it contradicts the
code, the code is right and this needs a review.

> **History.** Nila began as a system-of-record for a family field-service business
> (archived intact in `nila-ops`), pivoted to a CA AI-labor engine, and the wedge then
> sharpened from bank-statement classification to **GST**. The thesis then sharpened
> again — from horizontal *assistance* (make every junior faster) to vertical
> *ownership* (take bounded client-months end to end). The portable substrate
> (extraction, tenancy, GST helpers, banking spine, audit, storage) carries through.

---

## 1. Problem & users

Indian Chartered Accountant (CA) firms sell their clients' compliance work. The work
itself is high-volume, repetitive cognition done by junior staff: chasing clients for
documents, reading invoices and statements, typing them into structured records,
reconciling against the portal, assembling monthly returns. It is unstructured→structured
translation plus coordination that has historically required a human clerk.

**First user.** A CA firm's partner who carries the cost of that junior labor and signs
behind its output.

**The pain.**

- **Junior-staff time is the cost.** Collection, chasing, data entry, reconciliation and
  return assembly are the bulk of the hours a firm spends per client, and they scale
  linearly with client count — more clients means more juniors.
- **The bottleneck is collection, not calculation.** The month can't close because the
  documents aren't in yet; everyone submits on the last day, so the partner stays late.
- **Errors are stochastic and costly.** A mistyped invoice or a missed mismatch surfaces
  late, as a notice, a wrong return, or lost ITC.
- **The work doesn't compound.** Every month is re-done from scratch; nothing the firm
  learns about a client's patterns — this vendor is always ITC-blocked, this treatment is
  standard — is captured as leverage.

## 2. What Nila is

Not an assistant — an **AI accountant** that owns a bounded block of work. The firm can
hand Nila a defined set of client-months and say: *take these from document collection to
review-ready, bring the senior only the decisions that need professional judgment.*

The distinction is deliberate. **Horizontal assistance** makes every junior 20–30% faster
but the firm still needs the same people to own every client — the value doesn't justify
reorganising the team (this was a real partner's objection, and it's the trap). **Vertical
ownership** removes a concentrated, measurable block of work: Nila does the junior's
execution and first-level judgment underneath a senior, so a firm can take on more clients
without adding juniors. It starts by replacing junior execution and moves upward into
senior leverage; it does **not** claim to replace the senior.

**The deliverable is a place, not a file.** A generated PDF or Excel is a dead artifact —
to trust a number a CA has to have a senior re-derive it, which *adds* review work. Nila's
surface is a live, interrogable workspace: the month is worked, and every number is one
tap from its own scanned evidence, so checking Nila is faster than redoing it. That is
what collapses the senior's job instead of doubling it.

## 3. The wedge: GST

GST is the compliance stream with the **highest frequency** — GSTR-1 and 3B recur every
month for every registered client, so the volume is there to automate against and the
feedback loop is monthly, not annual. TDS (quarterly) and ITR (annual) come later on the
same engine.

The wedge has two halves that play different roles:

- **Reconciliation is the proof.** Purchase invoices reconciled against the portal's
  GSTR-2B, exceptions flagged with evidence, ITC reproduced against what was filed. This
  proves competence in one meeting against an answer key — hand Nila an already-filed
  month and it regenerates the firm's own workings and lights up the exact rows a human
  adjusted. It earns the meeting; it is not, by itself, the thing that saves the most
  hours (a partner has already shrugged at reconciliation alone).
- **Collection + chasing is the product and the moat.** The real bottleneck is that
  documents don't arrive; the recurring labor and the coordination pain live here. Nila
  chasing every client relentlessly and processing each document the moment it lands — at
  a concurrency and persistence a junior structurally can't match — is what makes the
  month review-ready early and makes Nila un-removable once inside. This is the harder,
  unbuilt half.

The sequence follows from that: reconciliation opens the door; collection is what Nila
does once through it.

**Nila files nothing.** It stops at review-ready workings and orchestrates the filing-time
OTP relay; a human reviews and clicks file. This keeps statutory accountability with the
firm and dissolves the "software files my client's return" trust problem.

Why sell to CA firms, not SMBs direct: they already own the relationship, the data access
and the statutory sign-off; the work is homogeneous across their clients (one engine, many
clients); and the ROI is a wage line they feel directly. The pitch that works is against
the *labor* budget ("this owns these client-months"), not the *software* budget (where it
fights for scraps against tools the firm already churns).

## 4. The long-term moat: accounting memory

A generic model can read an invoice; it does not know that a particular vehicle should be
capitalised, that a vendor is regularly misclassified, how this client's chart of accounts
works, or what correction the senior made last month. Nila accumulates that client-specific
context and improves through reviewer corrections — every resolved exception is captured as
raw data, and recurring patterns become remembered treatments applied automatically next
month. This is what eventually lets one senior supervise far more clients. We do **not**
model the memory prematurely; we capture corrections faithfully now and learn the
abstraction from real data.

## 5. Non-goals

- Not a full accounting suite or a Tally replacement — Nila's output slots into the firm's
  existing systems (Tally / Winman / portal), it doesn't replace them.
- Not removing the CA's judgment or statutory sign-off — **Nila drafts and readies, the CA
  reviews and files.**
- Not autonomous filing: uncertain lines always route to a human, and no return is
  submitted without human review.
- Not a chatbot / horizontal assistant bolted onto the firm's existing workflow.
- Not TDS or ITR yet — same engine, later, once GST earns trust.

## 6. What's built

The full month loop, both returns, end to end:

- **The GST engine** (`Nila.Gst`) — sales-bill extraction → derived GSTR-1 with
  validation issues; purchase invoices reconciled against GSTR-2B with a "flag, don't
  guess" matching ladder; validation flags (duplicate scans, invalid GSTINs, blocked
  ITC, tax-arithmetic, implausible values); the ITC position; the assembled GSTR-3B
  consuming the *signed* GSTR-1. Validated end-to-end on real filed months.
- **The human decision layer** — every exception ends in a recorded verb
  (confirm/reject/pick-the-right-2B-row/correct/accept-unmatched/dismiss, ITC
  block/allow), stored as append-only attributed resolutions, undoable, replayed over
  the pristine recon so every surface renders one projection. This is the correction
  capture the memory moat (§4) will learn from.
- **Certification** — per-artifact sign-offs (GSTR-1 and 3B separately) that freeze
  figures into snapshots; a signature is a wall (senior-only reopen, R1 reopen cascades
  to a dependent 3B); per-return filed marks with ARN; filed is immutable, and late
  documents are routed to the next open month.
- **Intake** (`Nila.Gst.Dumps`) — accretive dumps, one arrival at a time: each extracts
  on its own, the month derives from the union, a new 2B replaces the old, stragglers
  land without re-reading earlier piles. Multi-PDF piles. Dumps arriving behind a
  signature are held for senior release.
- **The screens** — Today (every client-month grouped by who it's waiting on, with
  chase drafts for clients who sent nothing), the client-month workbench (one room:
  GSTR-1, purchase recon, 3B, in filing order, evidence one tap away), the exceptions
  queue, Register (all-periods filed history), Clients, and intake.
- **Substrate:** auth + tenancy (orgs / entities / memberships), the
  document→structured **extractor** behind a swappable behaviour, GST jurisdiction
  logic, the audit log, pluggable storage, and email/WhatsApp ingestion scaffolding.
- **Frozen** (built for the earlier assistant/generic-workflow direction, kept but not
  the current path): the assistant chatbot (`Nila.Assistant`), the generic workflow
  step-runner (`Nila.Workflows`), and the bank-statement spine (`Nila.Banking` —
  reactivates later for full-bookkeeping clients).

The unbuilt half of the wedge (§3) remains **automated chasing** — today the chase is
drafts a human copies into WhatsApp and marks sent; Nila chasing relentlessly on its
own channel is the next milestone. Also deliberately unbuilt: amendments, cross-month
ITC carry, QRMP, photo intake — pulled by real usage, not pushed.
