# Sales review delight slice

_Decision and implementation-status note. Updated 2026-08-27._

## Outcome

Nila should finish the obvious Tally work and take the accountant directly through the
small remainder it cannot determine:

> Nearly finished vouchers → answer the irreducible choices → send the batch to Tally.

The delight is not an issue-management interface. It is that almost no work remains and
the accountant never hunts for what survived.

## Current status

The first residual-review slice is implemented:

- exact, company-scoped party, sales-line, and posting-profile mappings are reused;
- a first-time GST ledger is selected when synced Tally metadata exposes exactly one
  ledger for the required CGST, SGST, or IGST duty head;
- the batch excludes mapping-incomplete invoices from its ready count and exposes
  **Review N**;
- review mode contains only invoices still missing required Tally mappings;
- each invoice derives its next requirement in dependency order: party, printed sales
  lines, then applicable tax ledgers;
- **Go to** focuses the exact unresolved selector;
- mapping choices remain one invoice-local draft; and
- **Save & next** commits the complete posting atomically, advances only after success,
  and returns to the batch after the final unresolved invoice.

This removes hunting. It does not yet guarantee that the first run contains only a tiny
amount of mapping work.

## What is already authoritative

The review workbench already has enough deterministic state to identify missing posting
inputs without inventing accounting truth:

- party ledgers resolve from a saved company mapping, then exact GSTIN, then an exact
  normalized name;
- company posting profiles remember sales and tax ledgers;
- confirmed sales-line mappings resolve by normalized HSN/SAC plus description;
- invoice and line corrections persist through Phoenix; and
- the Tally posting save commits the party, line, and posting-profile choices together.

This is not another semantic verifier. The review sequence does not decide whether an
ambiguous invoice claim is true. It orders known missing inputs that Phoenix can observe
directly.

## Implemented: high and medium confidence

### Make obvious work disappear

1. Reuse an exact party match from the buyer GSTIN.
2. Resolve a unique first-time GST ledger from Tally's structured `GSTDutyHead`, then
   reuse the company's confirmed tax-ledger profile.
3. Reuse confirmed sales-ledger mappings for exact normalized HSN/SAC and description.
4. Reuse an identical resolved sales line within the current batch when that choice is
   already known from the company mapping store.

These defaults remain company-scoped. Nila does not infer a ledger from an arbitrary
human name when more than one candidate exists.

### Sequence only the residual posting requirements

The first sequence contains only inputs required to construct the Tally posting:

1. party ledger;
2. unresolved sales ledgers in printed line order; and
3. applicable tax ledgers after the invoice tax heads are known.

Accounting warnings remain visible but overridable under the demo contract. Connector,
company, and master-sync failures are excluded from the per-invoice mapping sequence;
fully consolidating their presentation remains a gap below.

### Use the existing batch and workbench

- The batch exposes **Review N** only when invoices still lack required Tally mappings.
- Review opens the existing invoice workbench in an explicit unresolved-invoice scope.
- The workbench identifies the next missing mapping and can take focus directly to it.
- Mapping choices remain an invoice-local draft.
- **Save & next** persists the complete posting atomically and advances only after the
  server confirms success.
- The last successful save returns to the batch.
- Directly opening an invoice retains ordinary all-invoice navigation and **Save & Close**.

## Remaining high and medium confidence gaps

These are not speculative workflow features. They are common work or trust boundaries
that the current slice still exposes.

### Remove repeated sales-ledger choices without fuzzy guessing

The first invoice may ask for the same sales ledger on several lines. Provide an explicit
way to apply a confirmed ledger to equivalent lines, starting with exact, explainable
signatures and the current invoice or batch. Do not silently treat unrelated descriptions
or HSN/SAC values as equivalent.

### Protect unsaved posting drafts

Mappings save atomically, but navigating away before **Save & next** can discard the local
draft. Invoice navigation, closing the workbench, and browser navigation must warn before
discarding dirty mapping changes.

### Invalidate dependent mappings explicitly

Changing a source fact such as buyer GSTIN or place of supply can change the applicable
tax heads. Incompatible tax mappings must be cleared, the requirement list recomputed,
and the user told exactly what changed. Nila must neither retain an invalid mapping nor
silently erase downstream work.

### Keep system blockers out of invoice work

Connector offline, configured company unavailable, and stale or unsynced masters are
company- or workbench-level conditions. They should appear once and must not inflate every
invoice's required-action count.

These gaps should be completed before describing the experience as the full delight loop.
Until then, the sequencer makes residual work navigable but a new company can still expose
too much repetitive work—for example, **Review 32**.

## Deliberately deferred

Do not build these until observed use earns them:

- sequencing professional warnings or recording acknowledgements;
- a generic action graph, action database table, workflow DSL, or exception sidebar;
- field-level mapping autosave, undo, or rollback UI;
- `Skip for now` and persistent deferral state;
- automatic fuzzy or cross-company ledger mapping;
- assignments, comments, approvals, or configurable review stages; and
- a keyboard-shortcut catalogue.

Keyboard support may activate the current target with Enter only after the click path is
proven and without intercepting an active form control.

## Truth and persistence boundaries

- A required mapping is derived from the effective invoice and the current posting
  draft; it is not stored as a new business object.
- A warning does not become a blocker merely because it appears in the review UI.
- The remaining count may change after a source correction, so copy uses `N required`
  rather than a fixed denominator.
- Nila never advances to another invoice before the posting transaction commits.
- A failed save leaves the reviewer on the same invoice with the draft intact.

## Completion

This slice is complete when a controlled batch can demonstrate:

1. exact known mappings are already selected;
2. the batch names only invoices that still need posting input;
3. **Review N** opens the first such invoice;
4. the next missing selector is reached without hunting;
5. **Save & next** persists and opens the next unresolved invoice;
6. the final save returns to a batch with no required mappings remaining; and
7. the existing single batch action sends every technically sendable voucher to Tally.

The success sentence is:

> Nila finished the batch, asked only for the mappings it could not know, and put the
> vouchers in Tally.
