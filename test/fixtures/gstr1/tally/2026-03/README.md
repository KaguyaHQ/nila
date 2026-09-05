# Table 8 supply matrix

Twelve native invoices dated 15-Mar-2026 cover each combination of registered/
unregistered and within-state/interstate for three supply categories:

| Documents | Treatment | Printed code | Values |
| --- | --- | --- | --- |
| NT-001–004 | Nil rated | 1006 | 1,100; 1,200; 1,300; 1,400 |
| NT-005–008 | Exempt | 9992 | 2,100; 2,200; 2,300; 2,400 |
| NT-009–012 | Non-GST | 2710 | 3,100; 3,200; 3,300; 3,400 |

Within each group the order is registered local, registered interstate,
unregistered local, unregistered interstate. Total supply value is 27,000;
GST is zero. These synthetic ledger classifications test software treatment,
not entitlement to an exemption for a real product or transaction.

All twelve PDF pages were rendered and visually checked. Extraction identifies
all three treatments. `review.json` confirms six unregistered places of supply.
Two non-GST lines print an amount without tax-rate or tax-inclusion evidence;
the engine now retains and resolves them using their explicit supply treatment.
Changing that treatment back to taxable removes the inferred amount again.

After review there are no workings issues. Every Table 8 amount, HSN financial
field and document count matches Tally. The score is 95.83: three B2C HSN `desc`
fields differ because Tally leaves them blank while Nila uses printed names.
Mixed taxable/non-taxable lines on one invoice and GSTR-3B Tables 3.1(c/e)
are not established by this fixture.

Captured on 2026-09-05 from disposable Tally company
`CALTECH GST PRACTICE - DEC 2025`, GSTIN `33BPBPK1081A1ZO`, GUID
`fb7551b0-e015-4489-bb16-135a58fa492d`. The fixture month was empty before setup.
`native-gstr1.json` is untouched native Export Offline JSON; nothing was filed
or uploaded to the GST portal.

Private corpus entry: `tally-caltech-2026-03-sales`, bucket `nila-eval-corpus`,
key `tally/caltech/2026-03/table8-nil-exempt-non-gst.pdf`, local mirror under `D:/eval-corpus/`.
No PDF or full model audit belongs in Git. `manifest.json` records source and
expected hashes and the private full-extraction archive. `extraction.json`
contains the compact, uncorrected replay input. `review.json` contains simulated
reviewer corrections replayed through production flagged-field restrictions;
it is neither model output nor a persisted human approval.

Run `mix test test/nila/gst/sales/tally_table8_test.exs`.
The benchmark in `eval/benchmarks/tally_sales_workings.exs` can rerun extraction
or replay scores using this fixture directory. It never connects to Tally.
