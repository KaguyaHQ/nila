# Business invoicing

## Local demo login

Run `mix nila.dev.reset` to rebuild disposable local data, then use **Business
workspace** under Development quick login at `/users/log_in`. The baseline opens
Example Business with its profile and no transactions. **Firm workspace** opens
the professional side for accounting firms and tax consultants.

Optional examples: `mix run priv/repo/business_seeds.exs` adds a customer, saved
item and draft invoice. See [development and demos](development-and-demos.md).
## Workflow

The business portal serves GST-registered domestic goods and service businesses.
Business owners can create an account at `/users/business_sign_up` with their
business name, GSTIN, owner name, email and password. A signed-in user can add
another business there without creating another login. Signup gives the owner
client-specific business access; they do not need a CA or firm invitation to begin.
An independently created business starts in its own org without firm membership. A CA can
also invite a business owner from the React client edit page. Connecting an
independently created business to a CA firm is not implemented yet. The owner sets
business details, adds customers, saves drafts when work is unfinished, or issues
directly from the filled editor, then downloads PDFs.

The invoice editor adapts Midday's editable document composition, inline fields,
line-item table, and customer picker/create/edit flow. The document is visible
before fields are complete. Phoenix calculates displayed amounts from the current
quantity, price, GST rate and place of supply; missing description or HSN/SAC does not
hide the document. Save and issue still validate the complete invoice.

An explicit Preview PDF action renders the current unsaved values without saving
a draft, allocating a number, or storing a PDF. Draft previews are marked DRAFT.
Issued previews read the same stored PDF used for downloads and CA evidence.
Optional reference/PO number, reference date and delivery address are retained in
the issued snapshot and PDF. The amount in words comes from Phoenix's saved totals.
Delivery address does not silently change place of supply. When its selected
state differs from the billing state, the editor asks the user to review the
place of supply before finalizing.

Each customer has saved addresses with a searchable label, state, optional GSTIN,
and billing/shipping use. The invoice chooses a bill-to address and optionally a
different ship-to address; a one-off typed ship-to address remains possible. The
selected billing address supplies the buyer GSTIN in the invoice and CA sales
source. Phoenix checks that both selected addresses belong to that customer.
Issued snapshots and PDFs keep the chosen buyer, consignee, address text and GST
details even if a saved address is edited later. Place of supply remains an
explicit choice. Existing customer address fields mirror the primary billing
address for older callers; the address rows are the selectable source.

Source comments identify the Midday components and pinned revision adapted to
Nila's APIs and Base UI shadcn controls.

Saved items live at `/app/business/:business_id/services`. Each business keeps its own
description, goods/service type, HSN/SAC, unit, default price and GST rate.
Goods require a 6 or 8 digit HSN and a supported unit (NOS, KGS, LTR, MTR,
BOX or SET); services retain six-digit SAC starting 99 and their free-text
unit. Invoice and quotation lines copy these defaults when selected; they remain
editable and independent of the catalogue. Editing or deleting a saved item
never rewrites an existing draft, issued snapshot or retained PDF. Ad hoc items
remain supported. There is no stock tracking.

Before the first invoice in the current financial year, Business details can set
the next invoice number and choose either Nila's `INV/2627/0001` format or a
simple `129/2026-27` format. The choice and next number lock after that year's
first invoice is issued. Drafts have no number. **Issue invoice** saves the
current editor values, allocates the number, renders the PDF, and creates the CA
sales source in one transaction. A failed issue leaves a new invoice unsaved or
an existing draft unchanged, with no number used. **Save draft** remains available
for unfinished work.

The portal is `/app/business/:business_id/invoices`, where `business_id` is the
authorized client ID. A user can access several businesses, including clients
invited from different CA firms, and can also belong to a CA firm. Business
requests check client-specific access independently of CA firm membership. The
business selector at `/app/business` appears when the user has more than one
business. Invitation links are returned for the CA to share; Nila does not send
them.

Quotations live at `/app/business/:business_id/quotations` and use the same editor and PDF
template. They have an optional valid-until date and a separate number series.
Before the first quotation in a financial year, Business details can set the
next number and choose either Nila's `QT/2627/0001` format or a simple
`79/2026-27` format. The format and next number lock once that year's first
quotation is finalized. A quotation can be finalized directly from the editor;
Phoenix saves the draft, allocates its number, renders and retains the PDF in
one transaction. A failed finalization leaves no partial draft or used number.

The optional Work / subject appears above the items in the editor and PDF.
Business details supply the seller phone, email, logo and optional signature
for new PDFs. These assets are scoped to the business; old finalized PDFs stay
unchanged when branding is updated. Goods lines require an explicit unit.

A finalized quotation cannot be edited. **Revise quotation** creates a linked
draft with its own number when finalized; the original PDF stays intact. The
business can mark a finalized quotation accepted or declined. Accepted
quotations convert into an invoice draft with the customer, items, prices,
subject, delivery address/state, place of supply, notes and references copied.
Conversion keeps a link to that invoice and retries return the same invoice.
The invoice date is today; quotation validity does not become a payment due
date.

Quotations and converted invoice drafts do not create sales sources or change
GST workings. Only issuing the resulting invoice does that. Finalized quotations
remain unchanged when the invoice draft is edited. The linked-conversion workflow
was checked against Bigcapital's SaleEstimates implementation.

Phoenix calculates amounts in paise and allocates a financial-year number while
holding the business/invoice locks. Issuing saves a snapshot, the PDF reference
and SHA-256 hash, and a sales source for the CA's existing working. Drafts stay
out of the working. Filed months reject new issues. Issued documents cannot be
edited; linked credit notes preserve the original document and cap credited
amounts by original item type, HSN/SAC, rate and tax amounts.

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
Place of supply is explicit because some supplies have special rules; the CA
must confirm the applicable place and tax rate. Existing CA checks remain active.
