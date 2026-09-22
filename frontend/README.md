# Nila React frontend

The sales summary, register, PDF uploads, upload history and invoice review use real
Phoenix data and the existing login. GSTR-1 section details open in React; workings
Excel and GSTR-1 JSON download from the existing Phoenix exporters. Sample screens
remain available only in Vite development.

The client directory at `/app/clients` also uses real data: search, add/edit name and
GSTIN, and Excel preview/import. Client names open the React sales workspace; edit
pages link to the existing GST/Tally connection settings.

## Run

With Node 20+ and npm installed:

```sh
cd frontend
npm ci
npm run build
```

Start Phoenix normally. Choose **Open new sales workspace** on an existing sales month,
or open `/app/gst/:client_id/:period/sales` on port 4000. The register ends in
`/sales/register`; PDF intake and history end in `/sales/upload` and `/sales/uploads`.
These pages use React Router; direct URLs and back/forward work.
GSTR-1 detail routes end in `/sales/sections/:section` for B2B, B2C, notes,
exports, SEZ, HSN and documents issued.
`/sales/checks` holds month-level document checks and their recorded decisions.
Confirmations cover the displayed source data; changed sources require a fresh review.

Purchases & ITC now opens at `/app/gst/:client_id/:period/purchases`.
Its source register is `/purchases/register?source=purchases` or `source=gstr2b`.
Sales and purchases navigate within React. `/purchases/review` provides source comparisons,
carried entries and audited ITC treatment, including save-and-next. Saves use the evidence
shown when the editor opened; a changed source requires a fresh review.
Purchase Excel import, portal fetching, source corrections and pairing still open LiveView.
GSTR-3B also stays in LiveView. Purchase APIs reuse existing totals, decision rules and signed snapshots.

For frontend edits alongside Phoenix, run `npm run build -- --watch` and refresh after
the build. Vite writes hashed assets to `priv/static/frontend/`. Phoenix serves them
on the same origin as the session and API. The Docker frontend stage packages these
assets into the same Phoenix release; there is no production Vite server.

`npm run dev` still serves sample screens at http://127.0.0.1:5173/sales.
Those sample routes are excluded from the production route tree.

```sh
npm run check
npm run build
npm test
```

Browser tests use installed Google Chrome and start their own Vite server on port 5174.
Controller tests cover authentication, tenant isolation and effective-working totals.

## Boundaries

- The read-only `/api/workspace/sales/:client_id/:period` endpoint gets the firm from
  the authenticated Phoenix scope. Amounts, classification and review states stay in Elixir.
- PDF intake uses signed upload URLs, then asks Phoenix to record the batch and queue
  the existing reading jobs. Mutation requests use the session CSRF token. Retrying
  the same batch submission does not create a second batch.
- Unfinished upload selections and retry tickets stay in memory when navigating
  between React pages. They are not retained after closing or reloading the app.
- Upload history polls saved processing states. Reading a file does not mean its
  invoices have been approved.
- Invoice review uses `/sales/invoices/:invoiceId`. Phoenix projects checks and
  totals and records corrections through the existing audited correction service.
  React reuses the existing PDF.js renderer, loaded only when opening a PDF.
- Development preview PDF selections stay in memory. Nothing is stored in localStorage.
- `src/data/sales.ts` owns the sample invoice rows and derived summary totals. Names,
  identifiers, and review states are demonstration fixtures, not verified tax facts.
- Sales Excel intake is not migrated. Required exports are workings Excel and
  GSTR-1 JSON; Winman, banking and Tally are outside the migration scope.
- TanStack Query owns server data, keyed by client/month. It refetches on window focus
  and polls while uploads remain unresolved. Search and filters live in the URL.
- Client/month changes never use the previous month's data as a loading placeholder.
- Routes still owned by LiveView use normal links and intentionally reload the document.
- Client API mutations enforce the existing edit permission. Excel previews use the
  existing parser and signed previews; saving rechecks duplicates in Phoenix.
- Deployment has not been performed.

## UI ownership

`src/components/ui/` contains shadcn components backed by Base UI primitives.
Their Base UI composition follows the official shadcn registry (MIT), while retaining
the preview's existing neutral styling and geometry. Imports point
to local components and `src/lib/utils.ts`. `components.json` supports future CLI use.

`src/index.css` owns this frontend's neutral theme and Inter typography. Change shared
buttons in `components/ui/button.tsx`; prefer component variants over page overrides.
The old HEEx recipes in `lib/nila_web/components/` remain for LiveView pages, not as
the visual source for this frontend. Do not copy sample-data shortcuts into production
accounting logic: Phoenix remains authoritative for validation and saved decisions.

References: [shadcn](https://ui.shadcn.com/docs/installation/vite),
[React Router](https://reactrouter.com/start/declarative/installation),
[Vite backend integration](https://vite.dev/guide/backend-integration).
