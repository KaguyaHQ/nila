# Unregistered credit and debit notes

Six native notes dated 15-Feb-2026 cover local B2CS (NU-CN-L, NU-DN-L),
interstate B2CS (NU-CN-S, NU-DN-S), and interstate B2CL (NU-CN-B, NU-DN-B).
Each credit is 2,000 plus 360 GST; each debit is 1,000 plus 180 GST.
Tally nets the first four into Table 7 and reports the last two in CDNUR.
The native HSN summary nets to -3,000, with IGST -360 and CGST/SGST -90 each.

The latest extraction reads all six embedded SACs. `review.json` supplies six
places of supply and four original-sale categories for interstate notes.
The note's own value cannot establish the original-sale category. The printed
reference dates do not establish cross-period original-invoice linkage; that
is not tested here. All six PDFs were rendered and visually checked.

After review there are no workings issues. Native financial, classification,
date and document-count comparisons match. The score is 96.83: only B2C HSN
`desc` and `user_desc` differ between the printed description and Tally masters.
The regression permits precisely those two text differences.

Captured on 2026-09-05 from disposable Tally company
`CALTECH GST PRACTICE - DEC 2025`, GSTIN `33BPBPK1081A1ZO`, GUID
`fb7551b0-e015-4489-bb16-135a58fa492d`. The fixture month was empty before setup.
`native-gstr1.json` is untouched native Export Offline JSON; nothing was filed
or uploaded to the GST portal.

Private corpus entry: `tally-caltech-2026-02-sales`, bucket `nila-eval-corpus`,
key `tally/caltech/2026-02/unregistered-credit-debit-notes.pdf`, local mirror under `D:/eval-corpus/`.
No PDF or full model audit belongs in Git. `manifest.json` records source and
expected hashes and the private full-extraction archive. `extraction.json`
contains the compact, uncorrected replay input. `review.json` contains simulated
reviewer corrections replayed through production flagged-field restrictions;
it is neither model output nor a persisted human approval.

Run `mix test test/nila/gst/sales/tally_unregistered_notes_test.exs`.
The benchmark in `eval/benchmarks/tally_sales_workings.exs` can rerun extraction
or replay scores using this fixture directory. It never connects to Tally.
