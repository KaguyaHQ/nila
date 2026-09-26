# Repeatable GST workings demo

Current contract, agreed September 7, 2026: scanned sales bills → reviewed sales
working XLSX → GSTR-1 JSON. [Presentation script](demo-script.md).
This supersedes the Tally-first presentation in [the archived August PRD](archive/demo-prd.md).

## Fixed packet

- Source: `D:/eval-corpus/sales/real/breeze-2026-06.pdf`.
- Presentation copy: `D:/nila-demo/breeze-2026-06/Breeze Tech - June 2026 - Sales.pdf`.
- SHA-256: `cfb7e59ee7085f083d081c5c4e77249a45214cc503c577693907701a99d47608`.
- Client: `BREEZE TECH - Demo`; GSTIN `33AEWPH4158J1Z3`; period `2026-06`.
- Eight scanned pages, eight single-page invoices, `38/2026-27`–`45/2026-27`.
- Local and interstate B2B, goods and services, and one 12-line invoice.
- All eight pages visually inspected on September 7. Use page 2 / invoice 39
  for the detailed source comparison; page 7 / invoice 44 shows the dense bill.

Recreate or verify the presentation copy without modifying its contents:

```powershell
./scripts/prepare-demo.ps1
```

The source and completed artifacts are private local files, not Git content.

## Expected figures and known source differences

Eight B2B invoices; taxable value **₹7,12,393.00**. The existing source-based
working reports CGST **₹45,948.33**, SGST **₹45,948.33**, IGST **₹36,334.08**,
and output tax **₹1,28,230.74**. Source invoice values total **₹8,40,623.74**.
Verify these after every live extraction.

The filed reference is
`test/fixtures/gstr1/breeze/2026-06/returns_04082026_R1_33AEWPH4158J1Z3_offline_others_0.json`.
It shortens invoice numbers to `/26-27`; the scan prints `/2026-27`. Preserve the
scan's numbers. This packet does not establish exact whole-return equality.

Invoice 43 prints **₹1,51,398.72**, while the old filed reference records
**₹1,51,398.12**. The resulting 60-paise difference explains why the source invoice
sum is ₹8,40,623.74 and the filed reference sum is ₹8,40,623.14. Nila preserves
the printed figure; do not change it just to match the old return.

Invoice 44 has printed line-tax sums of ₹34,950.36 each for CGST and SGST,
versus ₹34,950.33 each at the taxable-bucket level. The 3-paise difference in
each tax is within line rounding. Its printed invoice total is ₹4,58,237.66.
The workbook's source-tax checks may expose this; do not change the source to
force a green check. Explain the rounding if asked. The billed party and ship-to
state can differ; do not reinterpret tax treatment from the delivery address.

## Starting state and reset

The packet above is one rehearsed example, not a requirement of the demo system.
Use any client and packet suited to the audience. Create the client in the demo
firm and explicitly choose the correct month before uploading.

See [development and demonstrations](development-and-demos.md) for setup.
**Settings → Firm → Demo data → Reset demo** clears all clients and work across
all months in the designated demo firm. It preserves the firm and sign-in access.
Wait for running jobs to finish. Save any downloads needed for an offline fallback
before resetting; reset has no backup. Create the client again for the next run.

The September rehearsal records below describe an earlier client-specific setup.
Their fixed client IDs and old reset behaviour are historical, not current setup instructions.

## Pre-visit check

1. Confirm `nila.tax` login works and the correct demo client is selected.
2. Run packet verification; keep PDF, completed XLSX and JSON locally available.
3. Reset the demo firm if needed, create the packet's client, and confirm its working is empty.
4. Open Excel beforehand; check the downloaded workbook opens and formulas calculate.
5. Use the laptop's working internet connection/hotspot; live extraction needs it.
6. Keep the fallback files open. Do not diagnose AWS or run setup in front of the CA.

Operator access uses `scripts/prod-console`. See the setup guide for firm designation.

## Rehearsal record

September 7, localhost, started 10:19:36 UTC:

- Full scripted walkthrough: **3 minutes 38 seconds**, including **2 minutes
  55 seconds of fixed viewing/narration allowances**. This is an automated
  walkthrough paced for presentation, not a recording of spoken narration.
- Upload accepted at 21.0 seconds; eight invoices ready at 56.0 seconds:
  **35.0 seconds processing**. An earlier clean upload took about 47 seconds
  from the empty working to the finished batch.
- Invoice 39's source image loaded and its totals matched in the review screen.
- The actual downloaded XLSX opened and recalculated in Microsoft Excel. All
  six sheets had zero formula errors; summary and HSN totals matched the figures
  above. The expected 6-paise source-rounding check remained visible.
- JSON and optional Winman XLSM downloaded successfully. A reset followed by
  another live upload worked; the demo client was reset again after rehearsal.
  Final local reset took **1.59 seconds** including command startup and backup;
  inspection returned zero months, uploads, batches, attempts and decisions.
- Exact local timings: `D:/nila-demo/breeze-2026-06/local-rehearsal-timing.json`.
- Fallback files: `GST sales working.xlsx`, `GSTR-1.json`, `Winman B2B.xlsm`,
  and `Completed local run.png`, beside the source PDF in the demo folder.

The rehearsal exposed an HSN worksheet defect: without explicit POS, it treated
CGST/SGST source lines as interstate even though Tax Breakdown handled them
correctly. The deployed fix reuses the line-tax treatment already used by Tax
Breakdown, and widens HSN summary amount columns. Regression failed before the
fix and passed afterward. **32 relevant tests pass**, including demo reset,
workbook generation, special supplies and download controllers; compilation,
formatting, style guard and diff checks pass.

## Production rehearsal — September 7, 2026

Code commit `9340595` deployed successfully through
[GitHub Actions](https://github.com/KaguyaHQ/nila/actions/runs/34112116841).
The HSN export fix was verified in the actual production download using Microsoft
Excel, including the CGST/SGST/IGST split and absence of clipped numeric cells.

Production demo: organisation **1**, client **2**, `BREEZE TECH - Demo`.
Start: `https://nila.tax/gst/2/2026-06/sales`, after selecting that client in the
shell. Original client **1** is separate and is never a reset target.

The first live extraction produced eight invoices in **46.8 seconds**. Reset
archived that run at
`orgs/1/demo-backups/2/b3a79d00-4cd2-4ed2-be3d-28a993e0fb22.etf`.
The identical PDF then uploaded successfully into an empty working and produced
eight invoices in **44.2 seconds**. No source edits or invoice corrections were
needed. Invoice 39 matched the displayed source; Excel recalculated all six sheets
with zero formula errors. Counts, expected totals, HSN tax split and the 6-paise
source-rounding check were verified.

The complete production walkthrough took **3 minutes 49 seconds** (started
10:39:45 UTC). This includes **2 minutes 55 seconds of fixed presentation viewing
allowances**; it is an automated, presentation-paced browser/Excel run, not a
timed spoken delivery. Exact marks are in
`D:/nila-demo/breeze-2026-06/production-rehearsal-timing.json`.

Final production reset took **2.70 seconds**, including SSM connection and verified
backup. Backup:
`orgs/1/demo-backups/2/ad100ad6-70cf-4a8b-adbb-aefa254f98fa.etf`.
Inspection and the actual browser confirmed zero invoices, uploads and batches;
all demo month/attempt/decision counts were zero. The demo is left empty for the
next presentation. Original client 1 still has its eight June and fourteen November
invoices in the original worked months and uploads.

Production fallback files in `D:/nila-demo/breeze-2026-06/`:

- `Production working.xlsx`
- `Production GSTR-1.json`
- `Production Winman B2B.xlsm` (download verified; import into Winman not tested)
- `Completed production run.png`

The initial remote browser automation lost its temporary download handoff; the
production export endpoint returned the file successfully. The second walkthrough
used an isolated authenticated browser and verified the normal download click.
This was a rehearsal automation issue, not a required presentation step.
