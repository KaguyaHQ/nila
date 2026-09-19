# Sales Excel import

Open a client's sales month, choose **Add invoices**, then **Import an Excel sales sheet**.
The importer reads XLSX, suggests the sheet header and columns, and asks for confirmation
before adding invoices. It does not run OCR or approve GST facts.

Mapping shows each source column beside up to three distinct sample values and its
suggested Nila field. Unused columns remain visible as `Leave out`. Missing required
fields and duplicate field choices block the next step. A bare `RATE` heading is not
automatically treated as GST rate; the user must identify what its values mean.

The downloadable Nila template has a blank `Sales` sheet and a separate filled `Example`.
Examples are synthetic, dated August 2026. Delete or replace the examples before using
them for a client. Use one row per item or tax rate, with invoice details repeated.

## First-version boundary

- Ordinary taxable sales invoices only. Credit/debit notes, exports, SEZ, nil-rated,
  exempt, non-GST and reverse-charge sales are not supported by this importer.
- One sheet per confirmation. Other sheets are named in the preview and remain untouched.
- Match invoice number, date, taxable value, GST rate and at least one tax amount column.
  Enter rates in percentage points (`18` for 18%). Missing tax amounts are not invented.
- Customer registration can be `registered`, `unregistered` or `unknown`. A blank GSTIN
  alone does not establish that a customer is unregistered; it stays a review question.
- Taxable values and tax amounts are per row. Invoice total is the whole invoice's total,
  appearing once or repeated unchanged. Mixed-rate invoices retain separate lines.
- Quantity and unit of measure are optional per-row columns. Map them when present
  (for example, `10` and `NOS`) to retain quantities in HSN workings. Quantities must
  be non-negative numbers; units must contain a name or code. Blank values stay missing.
- Repeated invoice numbers form one invoice. Conflicting dates, customers, GSTINs,
  places of supply or totals block confirmation. Identical rows require duplicate review.
- Rows above the selected header are excluded. Total/subtotal rows are suggested exclusions
  and remain visible. Users may change exclusions. Any remaining invalid row blocks import.
- Mapped formulas and cell errors require pasted values. XLS/CSV, password-protected files,
  summaries without invoice details and merged-cell carry-forward are not supported.
- Limits: 5 MB compressed, 25 MB expanded, 20 sheets, 5,000 data rows per sheet, 100 cells per row.

The original workbook, chosen columns, header and excluded row numbers are retained.
Each invoice records its source sheet and rows, visible in invoice review and Excel workings.
Confirmation saves an intake dump and Oban job together. The existing sales workflow handles
derivation and signed/filed-month restrictions. Repeat sheet uploads and existing invoice
number/date pairs are rejected under a client lock.

## Verification fixtures

`test/fixtures/sales_excel/` contains the same synthetic sales in three layouts:
`standard.xlsx`, `reordered.xlsx`, and `subtotals.xlsx`.
Expected result: two invoices, three source rows, taxable value ₹4,000,
CGST ₹90, SGST ₹90 and IGST ₹410. The second invoice has two tax rates
and an invoice total of ₹3,410, counted once.

These fixtures verify known layouts. They are not evidence of arbitrary client-workbook compatibility.
