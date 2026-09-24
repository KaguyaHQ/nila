# Business invoicing

## Local demo login

Run `mix run priv/repo/seeds.exs`, then open `/users/log_in` and click
**Dev Business** under Development quick login. Sign out of your firm account
first, or use a private window. The account (`business@nila.test`) opens
Demo Business Services, linked to Nila Dev CA, with a customer, saved service,
two draft invoices and one issued invoice with its PDF and CA sales entry.

These business seeds run only in development and preserve existing records.
To add them to an already-seeded local database, run
`mix run priv/repo/business_seeds.exs`. The issued invoice needs the configured
Typst executable, just like normal invoice issuance.

## Workflow

The first business portal serves GST-registered domestic service businesses.
The CA invites a business owner from the React client edit page. The owner sets
business details, confirms with their CA that e-invoicing does not apply, adds
customers, saves drafts, then issues invoices and downloads PDFs.

The invoice editor adapts Midday's editable document composition, inline fields,
line-item table, and customer picker/create/edit flow. The document is visible
before fields are complete. Phoenix calculates displayed amounts from the current
quantity, price, GST rate and place of supply; missing description or SAC does not
hide the document. Save and issue still validate the complete invoice.

An explicit Preview PDF action renders the current unsaved values without saving
a draft, allocating a number, or storing a PDF. Draft previews are marked DRAFT.
Issued previews read the same stored PDF used for downloads and CA evidence.
Optional reference/PO number, reference date and delivery address are retained in
the issued snapshot and PDF. The amount in words comes from Phoenix's saved totals.
Delivery address does not infer place of supply.

Source comments identify the Midday components and pinned revision adapted to
Nila's APIs and Base UI shadcn controls.

Saved services live at `/app/business/services`. Each business keeps its own
description, SAC, unit, default price and GST rate. Invoice and quotation lines
copy these defaults when selected; they remain editable and independent of the
catalogue. Editing or deleting a saved service never rewrites an existing draft,
issued snapshot or retained PDF. Ad hoc service lines remain supported.

The portal is `/app/business/invoices`. Business users have a separate client
access record and no firm membership. One business per user is supported.
Invitation links are returned for the CA to share; Nila does not send them.

Quotations live at `/app/business/quotations` and use the same editor and PDF
template. They have a separate QT number series and an optional valid-until date.
Finalizing retains the quotation PDF; the business can mark it accepted or
declined. Accepted quotations convert into an invoice draft with the customer,
services, prices, place of supply, notes and references copied. Conversion keeps
a link to that invoice and retries return the same invoice. The invoice date is
today; quotation validity does not become a payment due date.

Quotations and converted invoice drafts do not create sales sources or change
GST workings. Only issuing the resulting invoice does that. Finalized quotations
remain unchanged when the invoice draft is edited. The linked-conversion workflow
was checked against Bigcapital's SaleEstimates implementation.

Phoenix calculates amounts in paise and allocates a financial-year number while
holding the business/invoice locks. Issuing saves a snapshot, the PDF reference
and SHA-256 hash, and a sales source for the CA's existing working. Drafts stay
out of the working. Filed months reject new issues. Issued documents cannot be
edited; linked credit notes preserve the original document and cap credited
amounts by original SAC/rate and tax amounts.

Typst renders the snapshot using the bundled template and fonts: Switzer for
document text, with a size-matched Inter rupee symbol. Both business
downloads and CA source evidence read the saved PDF; they do not regenerate it
from current customer details. Failed rendering or storage leaves the invoice
unissued and rolls back the allocated number. A retry does not duplicate sales.

## Local use

Run `mix ecto.migrate`, then build the React frontend with `pnpm run build` in
`frontend/`. Install Typst 0.14.2 and set `TYPST_BIN` to its executable, or put it
on PATH. Windows development also checks `tmp/tools/typst.exe`. Restart the dev
server after changing its configuration.

Run the PDF tests with `TYPST_BIN` set; tests that need the actual compiler are
explicitly skipped when it is unavailable. Poppler's `pdftotext` is used by
the PDF tests. The production image installs checksum-verified Typst binaries
for amd64 and arm64; no runtime Node/Chromium or remote fonts are required.

For a separate client hostname, set `NILA_BUSINESS_URL=https://client.nila.tax`
and route that hostname to the same Phoenix app. This sets invitation links and
the allowed LiveView origin. DNS/TLS/production deployment are separate operations.

Scope excludes exports, SEZ, reverse charge, composition/exempt billing,
e-invoice IRNs, inventory, payment collection and automatic email/WhatsApp sending.
Place of supply is explicit because some services have special rules; the CA
must confirm the applicable place and tax rate. Existing CA checks remain active.
