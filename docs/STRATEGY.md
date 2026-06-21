# Nila — Strategy

_Why this market, this wedge, and this sequencing. Last reviewed 2026-06-21._

This is the reasoning **underneath** `prd.md`. The PRD says what we are building and for
whom; this file records *why those choices win* — the value model, the customer filter, the
wedge logic, and the bets — so they can be re-examined instead of re-derived. If this file
contradicts the PRD on what to build, the PRD wins.

---

## 1. The value, from first principles

Every compliance obligation is a stream of transactions wrapped in work that is not the
business itself: recording each one, classifying it, proving it to the state. That work
exists for three reasons:

1. The state demands verifiable structure (GST returns, reconciliations).
2. Information arrives unstructured (bank statements, PDFs, portal exports).
3. Translating messy reality into clean records has historically required human cognition —
   that is what a back-office clerk, and a CA firm's junior, *is*.

Nila eliminates #3 as a human job. Decomposed, a CA firm buys:

- **Labor arbitrage** — AI converts unstructured→structured cheaper than juniors.
  Value ≈ the junior wage bill spent on classification and reconciliation.
- **Margin expansion** — the firm bills the client the same and pays less to produce it.
- **Error elimination** — classification and reconciliation mistakes are stochastic; a
  calibrated, audited first pass prevents the class by construction.
- **Capacity** — the firm takes on more clients without hiring linearly.

## 2. Why sell to CA firms, not SMBs direct

- They already own the **relationship, the data access, and the statutory sign-off**.
- The work is **homogeneous across their clients** (bank statements, GSTR-2B) — one engine,
  many clients, instead of one integration per SMB.
- They feel the labor cost **directly**; the ROI is a wage line, not a vague "visibility."
- A CA signs behind the output, so they will tolerate human-in-the-loop and *demand*
  calibration — which is exactly the thing that becomes our moat.

## 3. The wedge: bank-statement classification

Narrow, high-volume, ground-truthable, and the input is a single artifact. It is the most
repetitive cognition in the firm and the easiest to score against a known-correct ledger.
GSTR-2B reconciliation is the **second act** — higher value, but it needs supplier-filing
data we don't yet have, so it follows once the classification loop earns trust.

## 4. The moat: calibration

Value compounds with the fraction auto-cleared **at signable accuracy**. Every human review
in the routing queue is a labeled example that tightens the next month's confidence. The
asset is not the model; it is the accumulated, firm-specific calibration that lets more
lines clear without a human — and that only a firm already using us can build.

## 5. Sequencing

1. Build the engine on the **family business's consented books** — ground truth in hand,
   no client-confidentiality friction.
2. Validate classification quality against **CA Excel** from the discovery sprint.
3. Then onboard a **design-partner CA firm** on their own clients.

## 6. Open questions

- **Pricing model** — per-client, per-transaction, or per-seat.
- **Data posture** — residency and client-confidentiality stance for CA-held data once we
  ingest beyond the design partner.
- **GSTR-2B source** — where supplier-filing data comes from for the reconciliation act.
