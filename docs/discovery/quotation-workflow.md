# Quotation workflow — the Philips/Siemens quote spreadsheet

Evergreen discovery on how the family currently produces customer quotes, drawn
from a real artifact: a 461-tab, 16 MB Excel workbook (`philips.xlsx`) holding
~6 years of quotes. This is the *quoting* counterpart to the receivables study in
[`customer-workflows.md`](./customer-workflows.md) — same business, the front end
of the same jobs.

Source artifact and the extractor used to read it live in
`scripts/philips_quotes/` (`extract.py` → `quotes.json`/`quotes.csv`,
`errors.py` → `errors.md`, plus working notes in `FINDINGS.md`). Re-runnable from
the source xlsx; nothing here is hand-transcribed.

## 1. How they work today

Each quote is a **hand-formatted tab** in one giant workbook. The workflow is
"duplicate the last similar tab, edit the numbers, rename it." Four consequences,
all visible in the data:

- The workbook is a **document store + print template**, not a dataset. Every tab
  is a styled letterhead page; the file is 16 MB of cell styling over ~14 rows of
  real data per tab (one image total, so it is *not* logos).
- Nothing is queryable. "How much did we quote Philips in 2025-26?" needs opening
  100+ tabs by hand. We had to unzip the xlsx and parse the XML to answer it.
- **Copy-paste rot**: 24 `Copy of …` tabs, 39 colliding quote numbers, stray
  `Sheet6`/`Sheet11` tabs that nonetheless hold real quotes.
- No source of truth for the running quote number; it is retyped per tab.

## 2. Real numbers (the corpus)

- **454** real quotes parsed OK; 5 genuinely empty tabs; ~2 non-quote tabs.
- **6 fiscal years**: 2021-22 → 2026-27 (peak 128 quotes in 2025-26).
- **₹9,93,15,194** total quoted value. Per-quote: min ₹1,895, median ₹56,328,
  max ₹22,76,220. Avg 4.1 line items, max 35.

### Channels (NOT Philips-only)

| channel | signal | ~count |
|---------|--------|-------:|
| Philips India Ltd | bill-to GSTIN PAN `AABCP9487A` (multi-state) | 379 |
| Siemens India Pvt Ltd | GSTIN `33AAVCS8021P1ZM` / `36AAVCS…` | 16 |
| GE Healthcare, hospitals, OEM firms | one-off GSTINs | ~25 |

This matches the receivables study's OEM set (Siemens, Philips, …). Philips
dominates quoting but the model must not assume a single customer. The 16 Siemens
quotes are **real quotes mis-filed in the Philips workbook** — a vivid symptom of
"one spreadsheet as the filing cabinet": customers leak across files. In Nila a
quote belongs to a customer record, so this misfiling is structurally impossible.

### The recurring catalog (seed data)

The trade is **HVAC / chiller / AC maintenance + turnkey** for hospitals
(CAMC = Comprehensive Annual Maintenance Contract). Top line items, normalized:

| count | item | likely SAC/HSN |
|------:|------|----------------|
| 150 | Chiller CAMC | 998719 |
| 143 | AC CAMC | 998719 |
| 133/112/54 | AC CAMC / Split / Duct, priced by **tonnage or TR** | 998719 |
| 44 | Labour charges | 998719 / 996519 |
| 31 | CMA for chiller | 998719 |
| 26 | Refrigerant gas (R-xx) | goods HSN |
| 24 | LPG cylinder | goods HSN |
| 20 | Courier & transportation | 996519 |

`998719` (maintenance/repair services) dominates. This set should seed a small
**service-template catalog** priced by tonnage/TR, plus consumables and logistics.

## 3. A real quote (shape)

```
Quotation
Quote No: 31/2026-27          Quote Date: 04.06.2026
Bill To: Philips India Ltd    Delivery Address: Leonard Hospital, Vathalagundu
C/o UPS SCS (India) Pvt Ltd, 21 MRH Road, Madhavaram 600066
GSTIN: 33AABCP9487A1ZG

S.No | Description       | HSN/SAC | Qty | Unit Price | Value  | Tax | Rate | Tax Amt | Total
1    | Oil Hose Routing  | 998719  | 1   | 13200      | 13200  | CGST| 9%   | 1188    | 15576
                                                              SGST | 9%   | 1188
TOTAL                                              13200          2376      15576
Total incl. tax (in words): Rupees Fifteen Thousand Five Hundred Seventy Six
```

Note the **CGST+SGST 9%+9%** split (intra-Tamil-Nadu supply). Karnataka /
Telangana / Kerala delivery sites would instead be **IGST 18%** — the data spans
all of these, so the quote must derive treatment from place-of-supply.

## 4. Defects → schema constraints

Every defect in the workbook is a rule the Nila model must enforce so it cannot
recur. Counts are from `errors.md`.

| defect | evidence | constraint |
|--------|----------|-----------|
| Duplicate quote numbers | 39 colliding `NN/FY`, mostly `Copy of` tabs | quote number is **system-assigned, unique per (entity, FY)**, never hand-typed |
| Blank / malformed number | 11 blank, 8 malformed (`129/205-26`, `7//2023-24`) | number **required**, generated from a per-FY sequence, validated `^\d+/20\d\d-\d\d$` |
| HSN stored as a float | 1,326 as `998719.0`, 252 in sci-notation | `hsn_code` is a **string** (already is on `LineItem`), validated against a code list |
| GSTIN typed by hand | 6 structurally invalid (failed checksum / "Un registered Person"); 2 carry the **seller's own** GSTIN under a Philips bill-to | bill-to GSTIN is **selected from the customer's `gstins` map**, format+checksum validated; never free text |
| Date as free text | `04.06.2026` strings, some blank | `quote_date :date`, defaults to today |
| Site buried in a cell | 198 distinct delivery sites | delivery site is a **first-class** field (customer + place-of-supply), drives CGST/SGST vs IGST |
| "Duplicate tab" workflow | 24 `Copy of` tabs | "new from existing" = **clone into a new record with a new number**, not a copied document |

## 5. Mapping onto the existing schema

A quote is a **pre-invoice**: the same parties, line items, and GST maths as
`Nila.Invoices.Invoice`, minus payment/GRN/job lifecycle, plus a quote-specific
status flow and number series. Reuse, do not reinvent:

- **Seller** → `Nila.Orgs.Entity` (`gstin`, `state`). The seller GSTIN is **not
  printed on this template**, so the selling entity/entities are TBD (see Q3);
  at least one associated proprietorship's GSTIN turned up via the 2 mis-entered
  Philips quotes. Each selling entity is one `Entity` row.
- **Customer / bill-to** → `Nila.Customers.Customer`. `gstins` is already a map,
  which fits Philips holding TN/KA/TG/KL registrations. The quote stores the
  chosen `billing_party_gstin`, picked by place-of-supply, not typed.
- **Money** → **paise integers** (`unit_rate_paise`, `*_paise`), `quantity`
  decimal, `gst_rate_bps` (18% = 1800), mirroring `LineItem`. The importer must
  convert the xlsx rupee floats → paise (×100, round) on the way in.
- **GST treatment** → `gst_treatment` (`cgst_sgst` | `igst`), derived from seller
  state vs `place_of_supply`; reuse `LineItem.validate_tax_split/1` rules
  (all-present-or-nil, sum reconciles, cgst≈sgst within 1 paise).

### Proposed (for the plan, not built here)

- `Nila.Quotes.Quote` mirroring `Invoice`: `quote_number`, `quote_date`,
  `place_of_supply`, `gst_treatment`, `billing_party_{name,gstin,address}`,
  `*_paise`, `status` (`draft → sent → accepted → converted | expired | lost`),
  belongs_to `entity` + `customer`, optional `converted_to_invoice_id`.
- `Nila.Quotes.QuoteLineItem` ≈ `Invoice.LineItem` (position, description,
  `hsn_code`, quantity, unit, `unit_rate_paise`, `gst_rate_bps`, tax split).
- Number assigned atomically at "send" time per `(entity, fiscal_year)`, exactly
  as `finalize_and_number` does for invoices.
- Accepting a quote **converts** it into a draft `Invoice` (copy line items),
  closing the loop into the receivables workflow already documented.

### Resolved

- **The Siemens stream is real.** GSTIN `33AAVCS8021P1ZM` belongs to **Siemens
  India Pvt Ltd** (the bill-to customer). The 16 quotes are genuine Siemens quotes
  that were filed in the Philips workbook by mistake, not a parse error.

### Open

1. **Selling entities** — how many GSTINs does the family quote under, and which
   is canonical? The seller GSTIN is **not printed on this template**, so it
   isn't in the corpus; only an associated proprietorship's GSTIN surfaced, via
   the 2 mis-entered Philips quotes. (Kaguya Media `33AALCK…` was dummy data and
   is unrelated.)
2. **Tonnage/TR pricing** — is there a rate card per ton/TR, or is each quote
   priced ad hoc? Determines whether the catalog carries rates or just templates.
3. The 39 duplicate-number groups and 8 malformed numbers were checked manually;
   their resolutions are not yet captured (see `scripts/philips_quotes/` if we
   decide to import rather than start clean).
