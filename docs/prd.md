# Nila — Product Requirements

> "The AI accountant."

_Intent doc. Last reviewed 2026-07-04._

This is **why Nila exists, who it is for, and what we will and won't build** — product
intent, not a snapshot of the code. Current state lives in the code and git history. This
file should change when the *product* changes, not when code ships. If it contradicts the
code, the code is right and this needs a review.

> **History.** Nila began as a system-of-record for a family field-service business
> (archived intact in `nila-ops`), pivoted to a CA AI-labor engine, and the wedge then
> sharpened from bank-statement classification to **GST**. The portable substrate
> (extraction, tenancy, GST helpers, banking spine, audit, storage) carries through.

---

## 1. Problem & users

Indian Chartered Accountant (CA) firms sell their clients' compliance work. The work
itself is high-volume, repetitive cognition done by junior staff: reading invoices and
statements, typing them into structured records, assembling monthly returns, chasing
mismatches. It is unstructured→structured translation that has historically required a
human clerk.

**First user.** A CA firm's partner who carries the cost of that junior labor and signs
behind its output.

**The pain.**

- **Junior-staff time is the cost.** Data entry and return assembly are the bulk of the
  hours a firm spends per client, and they scale linearly with client count.
- **Errors are stochastic and costly.** A mistyped invoice or a missed mismatch surfaces
  late, as a notice or a wrong return.
- **The work doesn't compound.** Every month is re-done from scratch; nothing the firm
  learns about a client's patterns is captured as leverage.

## 2. What Nila is

Not an assistant — an **AI accountant**. It does the junior's job: the user dumps the
unstructured mess (PDFs, photos, pastes, forwarded mail), Nila extracts, classifies, and
drafts the structured artifact, and the human only touches the exceptions before anything
commits. The loop is dump → draft → review; the CA reviews and signs.

## 3. The wedge: GST

GST is the compliance stream with the **highest frequency** — GSTR-1 and 3B recur every
month for every registered client, so the volume is there to automate against and the
feedback loop is monthly, not annual. TDS (quarterly) and ITR (annual) are real work but
too infrequent to learn on; they come later on the same engine.

**First loop: GSTR-1 drafting.** Dump the month's sales invoices; Nila extracts and drafts
the GSTR-1 return lines; the human reviews the flagged ones and signs. After that, on the
same engine: GSTR-2B reconciliation (purchase invoices vs the portal's 2B) and 3B.

Why sell to CA firms, not SMBs direct: they already own the relationship, the data access,
and the statutory sign-off; the work is homogeneous across their clients (one engine, many
clients); and the ROI is a wage line they feel directly.

## 4. Non-goals

- Not a full accounting suite or a Tally replacement.
- Not removing the CA's judgment or statutory sign-off — **Nila drafts, the CA signs.**
- Not autonomous: uncertain lines always route to a human before anything commits.
- Not TDS or ITR yet — same engine, later, once GST earns trust.

## 5. What's built (substrate)

Auth + tenancy (orgs / entities / memberships), the document→structured **extractor** (the
crown jewel), GST jurisdiction logic, the bank-statement spine (`Nila.Banking`), the audit
log, pluggable storage, an Oban-backed workflow step-runner, email/whatsapp ingestion, and
the assistant. The GST engine (extract invoices → draft return lines → review queue) is
built on top.
