# Purchase review

Open **Purchases & ITC** for the selected client and month. The overview shows the two
inputs, reconciliation groups, outstanding checks and the ITC working. It shares the
Sales month picker and `[` / `]` shortcuts. Reconciliation is shown only after both
inputs are imported; a saved portal fetch awaiting import keeps the working in draft.

**View purchase register** and **View GSTR-2B** open the individual imported source
records. Reconciliation rows open filtered review lists under `/purchases/register`;
filters and search stay in the URL when opening or returning from an invoice. Source
totals include each document once, subtract credit notes, and retain original values.
Matching does not establish ITC eligibility.

## Inputs

- **Download template** on the purchase Excel importer provides a blank `Purchases`
  sheet and a filled `Example` with synthetic September 2026 transactions. Fill the
  blank sheet with ordinary taxable invoices, or upload an existing register instead.

- Import an XLSX purchase register, map columns, inspect totals and confirm. The first
  version supports ordinary taxable invoices, including repeated item rows grouped by
  supplier GSTIN, invoice number and date. It requires explicit tax heads, preserves the
  original workbook and records sheet/row references. Unsupported documents and formulas
  are reported rather than silently converted.
- Fetch GSTR-2B through the portal screen. A successful requested fetch adds the statement
  to reconciliation and opens Purchases. For an already fetched statement, **Review purchases**
  continues directly from the saved result; downloading JSON is optional. This snapshots
  the saved JSON into intake. Later fetched versions
  retain earlier source snapshots. The bridge supports B2B and credit/debit-note sections;
  nonempty unsupported sections block import with an explanation.
- Uploads requiring confirmation remain visible with their reason. Purchase uploads can
  be kept with a reason, moved or left out. A portal statement cannot move to a different
  return month.

## Review and output

Open an item to compare aligned source values beside a review queue. Choose a supported
pending, document or ITC decision, then **Save and next** (`Ctrl/Cmd+Enter`). The next
item comes from the refreshed queue. Purchase amount corrections still require their
source-based reason; corrections are audited overlays and do not change source files.

Pairing changes are postponed. Suggested pairs show **Pairing needs review** and cannot
receive treatments, including ITC checks on any member of an ambiguous group. They stay
unresolved. Tax mismatches remain outstanding until their underlying difference is
resolved; there is no generic acknowledgement or blanket claim approval.
Signed/filed months and read-only users cannot change decisions.

The list also supports selecting invoices directly from GSTR-2B before books arrive.
Choose **Set ITC treatment**, then **Claim in this month**, **Claim later**, or
**Exclude from ITC**. Matching alone does not record a claim. Claim is unavailable
while the invoice lacks the required evidence or has an unresolved blocking check.
Deferral and exclusion use structured reasons; notes are optional except for **Other**.
Selection survives supplier searches and the action bar shows the selected tax amount.

**Split treatment** is available for one invoice. Claim, later and excluded amounts
must add up separately for each tax head. Invoice taxable value stays intact.
Zero cess controls are hidden. Non-zero source cess stays visible for separate review;
Nila cannot claim or defer it, including through split treatment or signoff. A reviewed
exclusion can retain that amount while ordinary GST receives its own treatment.
Historical records, imports, reconciliation and fixed export fields retain cess.
The document date determines the source warning; viewing an old invoice in a new month
does not turn it into a current supply.
The overview and Excel use the same recorded treatment amounts.

Unclaimed balances appear as **Carried credit** in subsequent months, including months
with no new imports. They retain their source month and do not inflate that month's
purchase register or GSTR-2B totals. If an earlier portal-only invoice has now arrived,
**Client holds invoice** records that fact in the current month before claiming. A later
claim consumes only the remaining balance.
Within an open month, replacing a treatment records a new event. A treatment cannot be
changed behind a later-period decision or an active signed claim. Signed snapshots stay
fixed. Moving an invoice to another case after treatment is blocked to preserve its balance.

This records treatment in Nila's working; it does not file a claim, change an IMS action,
or record a statutory reversal/reclaim. Those remain separate workflows.

**Download working** exports the projected register, portal records, findings and ITC
position. It is a review working, not a filed return or a claim that all ITC is eligible.
Frozen months export the recorded signoff snapshot.

This flow does not post purchases to Tally or perform IMS actions. It does not revive the
old single-page purchase workbench. The old backend remains shared where needed.

## Development migration

The partial-claim migration changes live allocation uniqueness from one claim per invoice
to one claim per invoice per month. It retains all allocation rows. Rolling it back after
an invoice has claims in multiple months requires a deliberate data plan; the old index
cannot represent those records and rollback will fail rather than delete them.
