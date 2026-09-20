# Excel import templates

From the repository root, with the normal Elixir dependencies installed:

```sh
mix run --no-start scripts/excel_templates/generate.exs
```

Close these workbooks in Excel first. The script replaces both downloadable files
in `priv/templates/`, using the existing `xlsx_writer` dependency. Commit the
generator and regenerated workbooks together. No Node tooling is required.
Set `NILA_TEMPLATE_OUTPUT` to generate into a different directory for inspection.

Each workbook has a blank entry sheet and a synthetic `Example`. Example periods
are August 2026 for sales and September 2026 for purchases. There are two invoices
and three item/rate rows in each: taxable 4,000; CGST 90; SGST 90; IGST 410.

After changes, run the sales/purchase Excel importer and template controller tests,
and open both workbooks to check readability, gridlines and frozen headers.
