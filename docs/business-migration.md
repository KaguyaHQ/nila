# Nila Business migration packets

Use a migration packet when an agent needs to move customers, addresses, saved items and
quotations from an existing workbook into Nila Business. The source workbook may use any
layout. The packet is the stable boundary that Nila validates.

Do not add source-specific row or sheet rules to Nila. The agent reads the source, prepares
the packet and records every uncertain fact in `unresolved`. Nila refuses to write anything
until that list is empty and the packet passes its own business validation.

## Run the importer

Dry-run is the default:

```powershell
mix nila.business.import `
  --client-id 123 `
  --actor-id 456 `
  --packet outputs/business-import.json `
  --dry-run
```

After reviewing the counts, warnings and calculated totals:

```powershell
mix nila.business.import `
  --client-id 123 `
  --actor-id 456 `
  --packet outputs/business-import.json `
  --apply
```

`--apply` creates or reuses customers, addresses and saved items before importing the
quotations. Rerunning the same packet reuses an identical finalized quotation. A document
with the same number but different facts stops the import. Imported historical quotation
numbers do not advance or reset the business's live quotation counter. `--actor-id` must be
a user who already has access to that business; Nila records that user on imported documents.

## Packet shape

```json
{
  "version": 1,
  "source": {
    "file": "source.xlsx",
    "sheets": ["Quotation 57"]
  },
  "unresolved": [],
  "customers": [
    {
      "ref": "customer-one",
      "name": "Customer One Pvt Ltd",
      "address": "Primary billing address",
      "state_code": "29",
      "gstin": "29AAVCS8021P1ZB",
      "primary_address_ref": "customer-one-billing",
      "addresses": [
        {
          "ref": "customer-one-pune",
          "label": "Pune delivery site",
          "address": "Delivery address",
          "state_code": "27",
          "usage": "shipping"
        }
      ]
    }
  ],
  "services": [
    {
      "ref": "consulting",
      "description": "Consulting",
      "kind": "service",
      "sac": "998312",
      "unit": "service",
      "unit_price": "1000.00",
      "gst_rate": "18"
    }
  ],
  "quotations": [
    {
      "source_ref": "Quotation 57",
      "status": "issued",
      "number": "57/2026-27",
      "invoice_date": "2026-09-28",
      "customer_ref": "customer-one",
      "billing_address_ref": "customer-one-billing",
      "shipping_address_ref": "customer-one-pune",
      "place_of_supply": "27",
      "subject": "Annual maintenance",
      "lines": [
        {
          "service_ref": "consulting",
          "quantity": "1"
        }
      ],
      "expected_totals_paise": {
        "taxable": 100000,
        "tax": 18000,
        "total": 118000
      }
    }
  ]
}
```

References are packet-local identifiers. They connect quotations to customers, addresses
and saved items without using database IDs.

Each line may use a `service_ref` and override its copied description, HSN/SAC, unit, price
or GST rate. A line may also provide all those fields directly without creating a saved
item. Goods require an allowed unit. Dates use `YYYY-MM-DD`. Expected totals are integer
paise, not rupee strings.

Use `status: "issued"` for an already finalized historical quotation with a number. Use
`status: "draft"` without a number only when the source is unfinished.

## Agent checklist

1. Inspect the requested source sheets, including formula results and printed controls.
2. Preserve source wording and identifiers. Do not silently fix spelling or contradictory
   numbers.
3. Put every necessary assumption or contradiction in `unresolved` with its source and the
   proposed value.
4. Include source taxable, tax and grand totals in `expected_totals_paise`.
5. Run dry-run. Resolve every reported error and every `unresolved` entry with the user.
6. Run `--apply` only after the user authorizes the data write in the intended environment.

The importer does not interpret spreadsheets and does not guess tax facts. Phoenix remains
responsible for GST validation, arithmetic, immutable snapshots and PDFs.
