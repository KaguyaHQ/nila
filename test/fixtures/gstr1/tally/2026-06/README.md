# Outward RCM, SEZ and service exports

Six native Tally invoices dated 15-Jun-2026 exercise GSTR-1 Tables 4B, 6B
and 6A. All use SAC 998719 at 18%; these are synthetic treatment fixtures,
not evidence that an actual repair service qualifies for RCM or zero rating.

| Invoice | Treatment | Taxable | Invoice value | Reported GST |
| --- | --- | ---: | ---: | ---: |
| SDK3-RCM-L | Local outward RCM | 10,000 | 10,000 | 1,800 |
| SDK3-RCM-I | Interstate outward RCM | 20,000 | 20,000 | 3,600 |
| SDK3-SEZ-P | Same-state SEZ with IGST | 30,000 | 35,400 | 5,400 |
| SDK3-SEZ-L | SEZ under LUT/bond | 40,000 | 40,000 | 0 |
| SDK3-EXP-P | Export with IGST | 50,000 | 59,000 | 9,000 |
| SDK3-EXP-L | Export under LUT/bond | 60,000 | 60,000 | 0 |

Total taxable value: 210,000. Invoice value: 224,400. GSTR-1 reported GST:
19,800, including the 5,400 payable by RCM recipients. The RCM and LUT PDFs
print tax in an HSN summary while excluding it from the invoice total.
Nila preserves that printed evidence without adding LUT tax to the return.

Captured on 6-Sep-2026 from disposable company `CALTECH GST PRACTICE - DEC 2025`,
GSTIN `33BPBPK1081A1ZO`, GUID `fb7551b0-e015-4489-bb16-135a58fa492d`.
Native invoice PDFs (MasterIDs 72–77) were visually inspected and concatenated
without editing. `native-gstr1.json` is untouched Tally Export Offline JSON.
Nothing was sent to the GST portal. The native report included six invoices,
zero uncertain transactions and zero master conflicts.

## Model result and review

Both runs used production `alibaba/qwen3.7-flash` via `vercel-ai-gateway`.
The first run missed the local RCM footer and incorrectly increased its total:
that produced a silent wrong classification. It also overstated two other
printed totals. The extraction prompt now explicitly distinguishes invoice
payable from HSN tax and checks the combined export/SEZ endorsement against
recipient evidence. This improves the observed run, not a guarantee of OCR accuracy.

`extraction.json` is the compact, uncorrected second run. It gets all six totals
right but hallucinates RCM on the SEZ LUT invoice. The contradictory treatment
is blocked and held out. `review.json` records one simulated reviewer correction
of `reverse_charge` to false, based on the PDF; it replays through production
flagged-field restrictions and does not overwrite the original extraction.
The LiveView regression also exercises the payment and RCM selectors.

After this correction, all B2B/SEZ/export invoice fields and HSN financial
values match Tally, with no remaining review issues or internal silent errors.
Two differences remain deliberately visible:

- HSN descriptions: Nila uses source/official descriptions; Tally uses its ledger description.
- Table 13: Tally treats these manual voucher numbers as one series; Nila infers
  six series from their distinct suffixes. Total document count is six in both.
  This is not an exact whole-return match.

Scope is sales invoices and service exports. Special credit/debit notes remain
blocked. Goods-export shipping details and foreign-currency conversion are not
established here. The current Winman B2B workbook includes the two RCM invoices
and explicitly reports the four SEZ/export omissions; use GSTR-1 JSON for those.

The six-sheet GST working XLSX includes all six invoices and their distinct
treatments. Its summary invoice value excludes recipient RCM tax, the return
and HSN sheets report zero LUT tax, and the sales register/tax breakdown retain
printed tax evidence with an explicit note about LUT HSN summaries.

## Reproduction

The neighboring connector now creates GST sales and SEZ customer masters through
the typed Tally SDK. A second clean batch, dated 15-Apr-2027 and numbered
`SDK3-XP-*`, proves the final code works without manual voucher repairs: six
included, zero uncertain, zero master conflicts, identical financial fields.
June's original setup required iterative repairs; it is not presented as the
clean SDK reproduction. Intermediate experimental vouchers remain in the
disposable company for audit. See `nila-connector/docs/gst-fixtures.md`.

The PDF and both full model audits are private in `nila-eval-corpus`; keys,
SHA-256 hashes and the April native reproduction are recorded in `manifest.json`.
Each uploaded object was downloaded and byte-compared. No full audit or PDF is
committed. The corpus name is `tally-caltech-2026-06-sales`.

Run `mix test test/nila/gst/sales/tally_special_supplies_test.exs`.
Use `eval/benchmarks/tally_sales_workings.exs` to extract or score this directory.
