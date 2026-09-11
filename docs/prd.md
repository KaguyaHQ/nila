# Nila — Product Requirements

> "The AI accountant."

_Current objective reviewed 2026-09-11._

## Current objective

**Turn a CA firm's sales bills into an Excel workings file for GSTR-1, so the
junior does not have to read and type every bill and assemble the working by hand.**
The senior must be able to check the result, and the firm must be able to keep it
and later explain the figures. The first product ends at usable workings; the
firm retains responsibility for review and filing.

This section owns the current business objective. `AGENTS.md` carries the short
version; the README introduces it; demo documents explain how to demonstrate it.
Existing features and older strategy do not expand this scope. Code and tests
establish what is implemented, not what the business should prioritize.

### Why GST workings first

GST workings is the most recurring job identified in discovery so far. That
repeated preparation makes it the first product, ahead of TDS. Tally bookkeeping
has not emerged as a large enough need to lead with. This is the founder's current
priority based on the firms met so far, not a claim that every firm has the same
workload. Keep learning from real client months before expanding the scope.

### What we learned from the customer

The September 5 and 9 Balaji visit notes describe this workflow:

- A junior reads sales bills and enters them into a monthly Excel working.
- The work includes GSTIN/name checks, invoice-number checks, sales rows,
  tax arithmetic, and HSN summaries. Gaps and disagreements can require asking
  the client; copying text is only part of the work.
- A senior checks the working. The manager checks GSTINs, document counts by
  GSTR-1 table, taxable values, and totals before filing.
- The firm keeps the working to explain what was filed later. Its Excel template
  is distinct from the format its filing software accepts.

The practical starting point is the firm's scanned/PDF sales-bill work. The
notes also describe Tally, e-invoice reconciliation, chasing, and notice checking;
those observations are not commitments to expand the first product.

The manager reported late document arrivals, reminders, and work continuing late
near deadlines. We have not measured whether collection, preparation, checking,
client questions, or portal delays account for most of that pressure.

### What success means

On a real client month, an accountant can use Nila's file instead of preparing
the sales working from scratch. It contains recognizable invoice details,
source references, tax checks, HSN summaries, and traceable totals. Missing or
uncertain facts remain visible, with specific questions for the accountant.

Measure the preparation and checking still required, including corrections and
anything the accountant must add or calculate outside Nila. A fast extraction
or attractive workbook alone does not prove that the job is done. Preserve the
purpose of the firm's working and its review evidence; do not assume every
existing tab arrangement or formula must be copied.

GSTR-1 JSON is a supporting output. Tally and Winman handoffs can serve existing
workflows, but they are not prerequisites for the bills-to-workings result.
Existing WhatsApp, Tally, banking, and purchase features can remain. New scope
should follow observed needs; the current implementation priority is in
`AGENTS.md`.

### Evidence and limits

Primary notes live in the separate private CRM checkout:

- [Balaji visit, September 5](../../nila-crm/data/interactions/balaji-2026-09-05-visit.md)
- [Balaji walkthrough, September 9](../../nila-crm/data/interactions/balaji-2026-09-09-visit.md)

Local folder: `D:\nila-crm\data\interactions`. The links require the adjacent CRM
checkout. These are founder-recorded customer accounts and observations, not a
measured time study, a tax-law source, or proof of market-wide demand. A real
month checked with the accountant is the next source of product evidence.

Still unproven: which step is the main bottleneck, how much total time Nila saves
after review and corrections, whether firms will pay for that saving, and whether
chasing or remembered corrections would create a lasting advantage. The current
product is a choice to test, not a declaration that these questions are settled.

Earlier strategy and unvalidated ideas are kept in [the archive](archive/prd-history.md).
