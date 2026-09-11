# Historical product strategy

Superseded. See [the current objective](../prd.md) for current product decisions.

## Historical strategy — July 24, 2026 (superseded)

The remaining sections preserve earlier ideas, including unvalidated hypotheses.
Their collection-first,
purchase-reconciliation, and whole-month ownership priorities are historical,
not instructions for current work. Capability and workflow descriptions below
may also be outdated; check the code and tests before relying on them.

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

- **Labor-saving hypothesis.** Automating preparation might free staff time. We have
  not measured the share of time spent on each activity or how staffing scales with
  client count.
- **Collection hypothesis.** Late documents may contribute to deadline pressure.
  The customer reported late arrivals and reminders; that does not establish
  collection as the main bottleneck or explain all late working hours.
- **Errors are stochastic and costly.** A mistyped invoice or a missed mismatch surfaces
  late, as a notice, a wrong return, or lost ITC.
- **Knowledge-reuse hypothesis.** Software might help retain useful decisions across
  months. The firm already reuses templates and staff knowledge; we have not measured
  what additional benefit Nila could provide.

## 2. What Nila is

Not an assistant — an **AI accountant** that owns a bounded block of work. The firm can
hand Nila a defined set of client-months and say: *take these from document collection to
review-ready, bring the senior only the decisions that need professional judgment.*

The earlier hypothesis was that completing a bounded block of work would be more
valuable than assisting staff throughout their day. Neither a percentage productivity
gain nor the ability to take on more clients without hiring has been established.

**Earlier workspace hypothesis, superseded.** We expected an interactive workspace
to reduce review effort more than a generated file. That comparison was not measured.
The later customer notes show that Excel workings serve an ongoing preparation,
review, and retention job; usable workings are now the first deliverable.

## 3. The wedge: GST

We chose GST for its recurring preparation work in the firms encountered so far.
The current objective above records that choice; it is not a universal claim about
every client's filing frequency or the relative workload of every compliance service.

The wedge has two halves that play different roles:

- **Reconciliation as a demonstration hypothesis.** Comparing a reconstructed month
  with a filed reference might help demonstrate competence. It does not by itself prove
  customer value, time saved, or that the filed reference is correct.
- **Collection and chasing as a product hypothesis.** Reminders might reduce some
  coordination work. We have not established that they would bring documents in
  earlier, make the month ready earlier, or create a defensible business advantage.

The earlier proposed sequence was reconciliation, then collection. It was not a
validated sales or adoption sequence and is not the current roadmap.

**Nila files nothing.** It stops at review-ready workings and orchestrates the filing-time
OTP relay; a human reviews and clicks file. This keeps statutory accountability with the
firm and dissolves the "software files my client's return" trust problem.

The earlier commercial hypothesis was to sell preparation capacity to CA firms,
which already manage client compliance work. Willingness to pay, buying criteria,
and the value of that pitch remain to be tested.

## 4. Earlier hypothesis: accounting memory

Retained corrections might help with similar work in later months. Whether that
improves accuracy, saves review time, or creates a competitive advantage is unproven.
Recording a correction is not evidence that a system has learned a reusable rule.
Preserve correction evidence for the current job; do not build a memory system on
the strength of this hypothesis alone.

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
- **Intake** (`Nila.Gst.Intake.Dumps`) — accretive dumps, one arrival at a time: each extracts
  on its own, the month derives from the union, a new 2B replaces the old, stragglers
  land without re-reading earlier piles. Multi-PDF piles. Dumps arriving behind a
  signature are held for senior release. **Preconditions**
  (`Nila.Gst.Intake.Preconditions`) run between reading and deriving: a packet
  dated outside its month, a packet already booked in another month, or a
  books/2B pair with nothing in common stops as one question with three answers
  (move / keep with a recorded reason / discard) instead of becoming a queue of
  exceptions nobody can answer.
- **The screens** — Today (every client-month grouped by who it's waiting on, with
  chase drafts for clients who sent nothing), the client-month workbench (one room:
  GSTR-1, purchase recon, 3B, in filing order, evidence one tap away), the exceptions
  queue, Register (all-periods filed history), Clients, and intake.
- **Substrate:** auth + tenancy (orgs / entities / memberships), the
  document→structured **extractor** behind a swappable behaviour, GST jurisdiction
  logic, the audit log, pluggable storage, and email/WhatsApp ingestion and chasing.
- **Frozen** (built for the earlier assistant/generic-workflow direction, kept but not
  the current path): the assistant chatbot (`Nila.Assistant`), the generic workflow
  step-runner (`Nila.Workflows`), and the bank-statement spine (`Nila.Banking` —
  reactivates later for full-bookkeeping clients).

Automated chasing is built for consented email and WhatsApp channels, including a
period-bound WhatsApp completeness question whose signed replies become intake evidence.
Cross-month ITC custody now carries original invoice credits from books to a later 2B,
tracks missing-document decisions per invoice, and prevents duplicate claims at sign-off.
Still deliberately unbuilt: the broader reversal/reclaim matrix, amendments, QRMP, and
photo intake — pulled by real usage, not pushed.
