# Purchase review

Open **Purchases & ITC** for the selected client. The purchase list and invoice review
are separate pages; problem buckets filter the list and remain in the URL when opening
or returning from an invoice. Matching does not establish ITC eligibility.

## Inputs

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

Open an item to compare source values, inspect outstanding checks, confirm or reject
pairings, record pending/document/ITC decisions, or correct purchase amounts with a reason.
Corrections are audited overlays; source files remain unchanged. Signed/filed months and
read-only users cannot change decisions.

The list also supports selecting invoices directly from GSTR-2B before books arrive.
Choose **Don't claim ITC**, enter a reason and save it for the selected invoices.
Selection survives supplier searches. The bottom action bar shows the selected count,
tax and how many selections are outside the current filter, without moving the rows.
The reason dialog lists the selected invoice numbers. Excluded
invoices remain visible with their reason; other invoices remain undecided. **Clear ITC
decision** returns an invoice to review. Decisions follow the invoice when books arrive
and appear in the Excel working without deducting the same credit twice.

**Download working** exports the projected register, portal records, findings and ITC
position. It is a review working, not a filed return or a claim that all ITC is eligible.
Frozen months export the recorded signoff snapshot.

This flow does not post purchases to Tally or perform IMS actions. It does not revive the
old single-page purchase workbench. The old backend remains shared where needed.
