# Repeatable GST workings demo

Current contract, agreed September 7, 2026: scanned sales bills → reviewed sales
working XLSX → GSTR-1 JSON. [Presentation script](demo-script.md).
This supersedes the Tally-first presentation in [the August PRD](demo-prd.md).

## Fixed packet

- Source: `D:/eval-corpus/breeze/2026-06/sales.pdf`.
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

## Starting state and setup

Production is the presentation environment. Localhost is for preparation and
recovery, not evidence that the production presentation passed.

The app currently takes an account's first organisation membership; a separate
organisation would require additional account setup. A **dedicated client in the
existing workspace** is the smaller repeatable boundary.

Production changes require explicit user authorization. Before setup, inspect
the production organisation through `scripts/prod-console`. Existing production
client 1 (`Breezetech`) and its June/November runs are not reset targets.

```powershell
# Local setup, already exercised; output gives the client ID and start path.
./scripts/demo.ps1 -Action Setup -OrgId 1

# Production setup, only after authorization. Creates one marked client,
# with no contacts, chasing, Tally connection or imports.
./scripts/demo.ps1 -Production -Action Setup -OrgId 1
```

The local demo client is **3**. Production demo client ID: **not created yet**.
Use the ID printed by setup; never substitute the existing client ID 1.

**Always select the demo client using the shell's client switcher first.** A direct
month URL does not update the client stored in the browser session. The upload
uses that session client. Check both the sidebar and importer name before sending.

Open `/gst/CLIENT_ID/2026-06/sales`. Expect zero invoices, no old uploads and no
signed/filed state. The historical June period must be explicit; the app's default
month changes with the calendar.

## Reset between visits

Close demo tabs and wait for extraction to finish. Save the completed workbook,
JSON and one result screenshot to the demo folder before the first reset. These
are the offline fallback and must not be overwritten by an incomplete run.

```powershell
# Inspect first. Replace CLIENT_ID with the setup output (local: 3).
./scripts/demo.ps1 -Production -Action Inspect -OrgId 1 -ClientId CLIENT_ID

# After authorization for this disposable client's resets:
./scripts/demo.ps1 -Production -Action Reset -OrgId 1 -ClientId CLIENT_ID -ConfirmReset 'RESET 1/CLIENT_ID/2026-06'
```

The operator returns removed row counts, a backup storage key and `NILA_DEMO_OK`.
It archives exact database rows through `Nila.Storage` and verifies the backup
bytes before deleting anything. It clears only the marked demo client's sales
month, uploads, batches, extraction attempts, completed jobs and review/correction/
removal records. The client, other clients, source PDFs and evidence objects remain.
This is a presentation reset, not permanent object-storage erasure.

Refuses other months, purchase work, signed/filed work, Tally handoffs, running
extractions or queued/retryable jobs. Do not bypass a refusal. Inspect and resolve
the cause. Repeating reset on an empty demo returns zero removed rows.

Backups are compressed Erlang term files under
`orgs/ORG_ID/demo-backups/CLIENT_ID/UUID.etf`. Retain the returned key; an operator
can inspect it with `Nila.Storage.get/1` and `:erlang.binary_to_term(bytes, [:safe])`.
Restoration is an explicit operator task, not an automatic part of the demo.

## Pre-visit check

1. Confirm `nila.tax` login works and the correct demo client is selected.
2. Run packet verification; keep PDF, completed XLSX and JSON locally available.
3. Inspect/reset the demo client, then confirm the June working is empty.
4. Open Excel beforehand; check the downloaded workbook opens and formulas calculate.
5. Use the laptop's working internet connection/hotspot; live extraction needs it.
6. Keep the fallback files open. Do not diagnose AWS or run setup in front of the CA.

AWS operator access expires independently of the website login. If needed, use
`aws login --profile nila` before leaving. This laptop initially lacked the Session
Manager plugin; preparation used the official AWS ZIP's packaged executable under
`tmp/demo-prep/ssm-plugin/bin`. `demo.ps1` finds that or the standard installation.
For another machine, follow [AWS's Windows installation instructions](https://docs.aws.amazon.com/systems-manager/latest/userguide/install-plugin-windows.html).
The wrapper uses the same SSM instance and container as `scripts/prod-console`;
it loads the operator script for that invocation, with no application deployment.

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
correctly. The local fix reuses the line-tax treatment already used by Tax
Breakdown, and widens HSN summary amount columns. Regression failed before the
fix and passed afterward. **32 relevant tests pass**, including demo reset,
workbook generation, special supplies and download controllers; compilation,
formatting, style guard and diff checks pass.

**Production remains pending:** deploy the tested HSN export fix, authorize/create
the production demo client, repeat the browser/Excel walkthrough on `nila.tax`,
record production timing and verify its reset. The existing production runs have
not been changed. Do not mark the overall task complete based on localhost alone.
