# Sales Bills to Tally — First Demo PRD

_Demo decision document. Agreed 2026-08-26._

This document defines the narrow product Nila must demonstrate before expanding the
accounting workflow. It is intentionally smaller than [`prd.md`](./prd.md). When a
short-term implementation choice does not affect safety or data integrity, the first-demo
outcome described here takes priority over architectural completeness.

## 1. Objective

Show a CA firm partner that Nila can take a batch of physical sales invoices supplied as
a PDF, extract the accounting data, and create the corresponding vouchers directly in
Tally in minutes.

The moment that matters is:

> Upload the bills, review what Nila noticed, click **Send to Tally**, and see the
> vouchers inside Tally where a junior would otherwise have typed them manually.

The demo earns permission to discover the firm's next workflows. It does not attempt to
prove that Nila already supports every client, document type, accounting convention, or
GST filing decision.

## 2. Audience and environment

- **First audience:** a CA firm owner or partner, because they control access to the
  firm's workflows and feel the cost of junior data-entry time.
- **First dataset:** a known, previously tested batch of real Breeze Tech sales invoices,
  potentially spanning multiple months.
- **First environment:** Nila and Tally running on the founder's laptop against a
  controlled demo company.
- **Next step if invited:** run the same workflow against invoices and Tally data from
  the partner's firm. Unsupported differences found there become evidence for what to
  build next, not failures to predict in advance.

The upload and processing should happen live. The exact demo PDF must be rehearsed
beforehand so extraction latency, output and connector behavior are known.

## 3. Product promise

Nila replaces the repetitive entry portion of the junior accountant's work. It does not
replace the senior's review or claim to be the final authority on the accounting or GST
treatment.

Nila must:

1. read the invoices;
2. produce recognizable invoice drafts;
3. call attention to specific concerns;
4. respect the accountant's decision to proceed;
5. create the supported vouchers in Tally through the connector; and
6. report the result for each invoice.

Validation supports the promise by preventing silent mistakes and demonstrating that
Nila understood the documents. Validation is not the centerpiece of the demo and must
not turn professional judgment into a workflow dead end.

## 4. Core workflow

```text
Upload one PDF batch
        ↓
Extract all recognizable sales invoices
        ↓
Show one batch table with status per invoice
        ↓
Review or correct the rows that need attention
        ↓
Click one prominent “Send to Tally” button
        ↓
Confirm once if accounting warnings remain
        ↓
Send every included, technically sendable voucher
        ↓
Show success or failure on each invoice row
        ↓
Open Tally and inspect the created vouchers
```

The batch is the unit of action. Nila must not force a clean subset to be sent first and
then make the user repeat the send flow for warned invoices.

## 5. Invoice status contract

Every invoice has one operational status:

| Status | Meaning | Included in batch send? |
| --- | --- | --- |
| **Ready** (green) | Nila found no unresolved concern. | Yes |
| **Needs review** (yellow) | Nila found an accounting, tax, extraction, or document concern, but it can technically construct a voucher. The accountant may overrule it. | Yes, after one batch confirmation |
| **Cannot send** (red) | Nila lacks information or capability required to construct and transmit a meaningful voucher. | No |
| **Not included** | The user deliberately excluded the invoice from this batch. | No |
| **Sent** | Tally accepted the voucher. | Never resend implicitly |
| **Send failed** | The connector or Tally rejected this voucher. | Retry this voucher only |

### Yellow: warn, then obey

Accounting concerns are not absolute gates. Examples include:

- missing or inferred HSN/SAC;
- an unusual GST rate;
- a rate-history conflict;
- printed and derived totals that disagree;
- a questionable CGST/SGST versus IGST treatment; and
- other concerns on which a senior may exercise judgment.

The review UI must state the evidence plainly. It must not expose raw validator messages,
invent a business conclusion, or prevent the accountant from proceeding.

### Red: technically impossible, not professionally questionable

Red is reserved for cases where Nila cannot perform the requested operation, such as:

- insufficient identity or amount data to construct a voucher;
- no usable party or ledger decision;
- a document/treatment the current Tally serializer cannot represent meaningfully;
- output that Tally would reject as malformed; or
- an unavailable connector.

Unsupported and red invoices are skipped without holding the rest of the batch hostage.

## 6. Batch send behavior

The main action sends all green and yellow invoices together. If one or more yellow
invoices remain, Nila shows a single confirmation before sending:

> Heads up — 3 invoices still have warnings: one missing HSN/SAC, one unusual GST
> rate, and one totals mismatch. Send 24 vouchers to Tally anyway?

After confirmation:

- send all included green and yellow invoices;
- skip red and `Not included` invoices;
- retain per-invoice status throughout the operation;
- show each Tally acceptance or failure on its invoice row; and
- allow retry of failed or unsent vouchers without duplicating successful vouchers.

Warnings must never be silently discarded. They remain visible before and after the
send, but they do not become permanent blockers.

## 7. Tally connector contract

The first demo uses the connector, not a manual XML-import workflow. One click from Nila
must result in vouchers appearing in Tally.

The send boundary must provide:

- **idempotency:** a repeated click, timeout, refresh, or retry must not create duplicate
  vouchers;
- **per-voucher outcomes:** partial failure is represented invoice by invoice rather than
  as one opaque batch failure;
- **safe retry:** retry only vouchers that are not already known to have succeeded;
- **dependency ordering:** when master creation is later supported, create and verify the
  approved master before sending its dependent voucher; and
- **honest capability handling:** skip structures the connector/serializer cannot yet
  represent rather than manufacturing different accounting semantics.

The batch screen is the operational record of what was ready, warned, excluded, sent, or
failed.

## 8. Voucher fidelity

At minimum, a generated voucher must preserve the fields a partner will immediately
recognize and inspect:

- invoice number;
- invoice date;
- party ledger;
- sales and tax ledger allocations;
- taxable value;
- CGST/SGST or IGST amounts; and
- final voucher total.

Whether the firm's normal entry includes item descriptions, quantities, unit rates,
HSN/SAC at line level, inventory allocations, or rate-specific sales ledgers is an
observed accounting convention, not something to guess.

The manually entered Breeze Tech vouchers and their exported XML are the technical
baseline for the first demo. They prove a valid structure that Tally accepts. They are
not assumed to be the universal convention; real partner vouchers determine later
mapping behavior.

## 9. Party ledgers

All buyers in the controlled first-demo batch currently have usable ledgers, so a full
party-master workflow is not required before the demo.

Reviewed in-context ledger creation is nevertheless required before Nila can credibly
handle arbitrary client batches:

```text
No confident party match
        ↓
Choose an existing ledger OR review a proposed new Sundry Debtor
        ↓
Send batch
        ↓
Create and verify the approved ledger in Tally
        ↓
Create the dependent voucher
```

Nila must not blindly create a ledger from every OCR party name. GSTIN is the strongest
matching key; normalized names may propose candidates, but ambiguous matches require a
human decision. Bulk master management is deferred until real usage requires it.

## 10. Cancellation and exclusion

Nila may identify an objective defect in an invoice, but it must not infer that the
invoice was cancelled. Cancellation is a historical business decision that may only
become known from later documents or the user's knowledge.

The user can mark an invoice `Not included` and optionally record a reason such as
`Cancelled/replaced`. Nila then excludes it from the Tally payload. The user remains able
to reverse that decision before sending.

## 11. Demo acceptance criteria

The first demo succeeds when:

1. a known multi-invoice Breeze Tech PDF is uploaded and processed live;
2. the batch screen presents recognizable invoices and specific review concerns;
3. no accounting warning creates an unresolvable dead end;
4. one batch action sends all included, technically sendable invoices through the
   connector;
5. per-invoice outcomes are visible, and retries cannot duplicate successful vouchers;
6. the created vouchers appear in the controlled Tally company; and
7. inspection in Tally shows the expected parties, dates, invoice numbers, ledger/tax
   allocations, taxable values, tax amounts, and totals.

The exact number of green versus yellow invoices is not an acceptance criterion. A small
number of genuine, clearly explained warnings may strengthen the demonstration. Opaque
failures, false claims, duplicate vouchers, or materially incorrect Tally entries do not.

## 12. Immediate engineering priorities

In order:

1. implement green/yellow/red/excluded semantics without making warnings permanent
   blockers;
2. make the single batch send include green and confirmed-yellow invoices while skipping
   red and excluded rows;
3. prove connector idempotency, partial-result reporting, and failed-only retry;
4. fix mixed-period validation so one invoice's month does not create false warnings on
   another;
5. ensure issue evidence shown to the user is the evidence produced by validation rather
   than recomputed UI guesses;
6. enforce only genuine technical inability at every demonstrated Tally send boundary;
7. compare generated vouchers with the manually entered Breeze Tech vouchers/exported
   XML; and
8. rehearse the complete PDF-to-Tally flow using the exact demo batch.

Keep shared invoice correctness checks centralized. Keep destination capability local:
GSTR-1 decides what the GSTR-1 generator can represent, while Tally decides what the
Tally serializer and connector can represent. Do not build a generalized abstraction
project merely to prepare this demo.

## 13. Explicitly deferred

These are valuable, but not prerequisites for the first spark of magic:

- audited persistence for every warning acknowledgement;
- generalized exception-history infrastructure;
- refactoring the frozen month screen's issue presentation;
- reviewed party-ledger creation and bulk master creation, while the controlled batch
  needs neither;
- purchase bills, credit notes, exports, SEZ and other unsupported voucher families;
- expanding the bank-statement workflow;
- universal accounting-convention mapping; and
- claiming that generated entries are ready for filing without the firm's normal senior
  review.

The boundary is simple: build what makes the controlled sales-bill batch visibly replace
junior data entry, protect that demonstration from silent or technical failure, and let
real partner feedback choose the next workflow.
