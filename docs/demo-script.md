# GST workings demo

Purpose: make the document-to-working workflow concrete, then let the accountant
judge where it fits. Aim for five minutes excluding questions; measured results
and preparation are in [the runbook](demo-runbook.md).

## Before showing the screen

Log into `nila.tax`. **Use the client switcher to select `BREEZE TECH - Demo`.**
Open its **June 2026** Sales & GSTR-1 working and confirm it is empty.
Production start page: `https://nila.tax/gst/2/2026-06/sales` (select the client first).
Have `D:/nila-demo/breeze-2026-06/Breeze Tech - June 2026 - Sales.pdf` ready.
Keep `Production working.xlsx`, `Production GSTR-1.json`, and
`Completed production run.png` from the same folder available offline.

## The sequence

1. **Source PDF — about 20 seconds.** Show page 1 and briefly scroll to page 7.
   “Here are eight scanned sales invoices. This one has twelve lines. Someone
   would normally read these and prepare the sales working.”
   These are eight single-page invoices; do not call this a multipage-invoice demo.

2. **Empty June working → Bring in invoices.** Select the PDF, wait for the upload
   to finish, then click **Add to Jun 2026 sales** once. Check the importer names
   `BREEZE TECH - Demo`. During processing, connect the task to the firm's own
   workflow; don't narrate the progress indicator.

3. **Batch result → inspect one invoice — about 45 seconds.** Expect eight
   invoices. Open **39/2026-27** (page 2): Siemens Healthcare, Telangana,
   taxable **₹68,552**, IGST **₹12,339.36**, total **₹80,891.36**.
   Show the source beside the extracted values. Resolve a real question if one
   appears and the source supports the answer. Do not manufacture a warning.

4. **Open Jun 2026 working → Download GST working — about 90 seconds.** Open the
   XLSX in Excel. Start with **Sales Register**, then **Tax Breakdown**, then
   **HSN Working**, and finish on **Summary**. Show recognizable invoice rows,
   reported/calculated tax checks, HSN aggregation, and B2B document count/totals.
   “This is the sales working your senior can check and retain.”
   Mention the 6-paise line-rounding difference only if the check is visible or
   they ask; use the exact explanation in the runbook.

5. **GSTR-1 summary → JSON download — about 20 seconds.** Show eight B2B invoices
   and the HSN/document summaries. Download JSON; no raw JSON tour. The Winman
   workbook is an optional handoff discussion, not a required live import.

6. **Return to their workflow.** “How does this compare with the sales working
   your junior prepares? What would they still need to do?” For Balaji, observing
   the junior and testing a real packet can follow. Let the conversation decide.

## If something stalls

At 90 seconds of processing without a usable result, continue with the previously
completed files: “This is an earlier completed run of this same packet.” Never
present cached output as the result of the current upload. Let the job finish
before resetting. For an unexpected review issue, inspect the source briefly;
if it cannot be resolved confidently, use the fallback and record the issue.

Skip Tally, banking, purchases, signing/filing, settings, and empty GST tables.
For a firm's own packet, keep the client and period separate from the disposable
demo client. That is a discovery exercise, not a promise of the rehearsed timing.

## After practising or between visits

On the demo client's Sales & GSTR-1 page, click **⋯ → Reset demo → Reset demo**.
Wait for processing to finish first. Save any downloads you want to keep before
resetting. The app opens the empty June working, ready for the same PDF again.
