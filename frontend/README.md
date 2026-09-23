# Nila React frontend

The sales summary, register, PDF uploads, upload history and invoice review use real
Phoenix data and the existing login. GSTR-1 section details open in React; workings
Excel and GSTR-1 JSON download from the existing Phoenix exporters. Sample screens
remain available only in Vite development.

The client directory at `/app/clients` also uses real data: search, add/edit name and
GSTIN, and Excel preview/import. Client names open the React sales workspace. Edit
pages show GST connection status and connect/reconnect through an OTP dialog in React.
Connecting here does not fetch GSTR-2B or start notice checks.

Notices at `/app/notices` uses React for the saved notice list, client checks, OTP
reconnection and document reader. Phoenix retains check runs and notice history;
opening the page does not reset what is new. PDFs use the existing authenticated
document endpoint. Reply and closure status are not inferred from notice dates.

## Run

With Node 20+ installed, install the pinned pnpm version once (`npm install --global pnpm@10.34.5`):

```sh
cd frontend
pnpm install --frozen-lockfile
```

Start Phoenix with `mix phx.server`; its development watcher starts Vite on port 5173.
Open the app on **http://localhost:4000**, not the Vite port. React edits use Fast
Refresh automatically; no build or manual refresh is needed. Restart Phoenix once
after changing development configuration. Login and `/app` open the React workspace (or the client
directory when no client exists). Open `/app/gst/:client_id/:period/sales` directly
on port 4000 for a particular month. The register ends in
`/sales/register`; PDF intake and history end in `/sales/upload` and `/sales/uploads`.
These pages use TanStack Router; direct URLs and back/forward work.
The code-based route tree lives in `src/app.tsx`; validated search contracts live in
`src/lib/route-search.ts`. Use typed `to`, `params` and `search` for new navigation.
`urlDestination` is the boundary for URLs supplied by Phoenix or preserved workspace
subpages. Query values stay plain strings so existing links and references keep their
meaning. TanStack Query continues to own server-data caching; Phoenix owns business rules.
GSTR-1 detail routes end in `/sales/sections/:section` for B2B, B2C, notes,
exports, SEZ, HSN and documents issued.
`/sales/checks` holds month-level document checks and their recorded decisions.
Confirmations cover the displayed source data; changed sources require a fresh review.

Purchases & ITC now opens at `/app/gst/:client_id/:period/purchases`.
Its source register is `/purchases/register?source=purchases` or `source=gstr2b`.
Sales and purchases navigate within React. `/purchases/review` provides source comparisons,
carried entries and audited ITC treatment, including save-and-next. Saves use the evidence
shown when the editor opened; a changed source requires a fresh review.
GST connection, OTP, fetching and preparation now stay in the React source card.
Failed refreshes retain the previous saved statement and its source JSON download.
Purchase Excel import, source corrections and pairing still open LiveView.
GSTR-3B also stays in LiveView. Purchase APIs reuse existing totals, decision rules and signed snapshots.

Keyboard navigation: `[` / `]` changes the month on overview/list pages; `g` then
`s` or `p` opens Sales or Purchases for the same client and month. `/` focuses list
search. `?` or the keyboard button opens help.
Navigation pauses in inputs, dialogs and invoice editors. Invoice review retains
Alt-arrow navigation; purchase treatment uses Ctrl/Cmd+Enter for save-and-next.

Run `pnpm run check` separately for TypeScript validation. For production,
`pnpm run build` writes hashed assets to `priv/static/frontend/`. Phoenix serves them
on the same origin as the session and API. The Docker frontend stage packages these
assets into the same Phoenix release; there is no production Vite server. Development
does not read that build folder, so rebuilding cannot interrupt the running app.

The same Vite server also serves sample screens at http://127.0.0.1:5173/sales.
Those sample routes are excluded from the production route tree.

```sh
pnpm run check
pnpm run build
pnpm test
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

`src/components/ui/` contains shadcn components backed by Base UI primitives;
Command uses shadcn's upstream `cmdk` implementation.
Their Base UI composition follows the official shadcn registry (MIT), while retaining
the preview's existing neutral styling and geometry. Imports point
to local components and `src/lib/utils.ts`. `components.json` supports future CLI use.

`src/index.css` owns this frontend's neutral theme and Inter typography. Change shared
buttons in `components/ui/button.tsx`; prefer component variants over page overrides.
The old HEEx recipes in `lib/nila_web/components/` remain for LiveView pages, not as
the visual source for this frontend. Do not copy sample-data shortcuts into production
accounting logic: Phoenix remains authoritative for validation and saved decisions.

Desktop navigation includes searchable client switching and Ctrl/Cmd+K for pages,
clients and months. The account menu opens React settings; sign-out remains owned by Phoenix. See the
[interaction audit](../docs/design/REACT-MIGRATION-AUDIT.md) for restored behavior
and the remaining deliberate LiveView handoffs.

References: [shadcn](https://ui.shadcn.com/docs/installation/vite),
[TanStack Router](https://tanstack.com/router/latest/docs/guide/navigation),
[Vite backend integration](https://vite.dev/guide/backend-integration).

## API contract

`priv/openapi/workspace.json` is the Phoenix-owned OpenAPI 3.1 contract for all
React JSON APIs: sales, uploads, clients/imports, purchases/ITC, GSTR-2B and
Business/invitations. It also documents the file downloads used by React.
The schema is explicitly maintained alongside controllers, not inferred from Elixir maps.

After changing a request or response, update the contract and run `pnpm run api:generate`
in `frontend/`. Commit both the schema and `src/lib/generated/workspace.ts`.
Do not edit generated types or duplicate DTOs in React. `pnpm run check` and the
production build reject stale generated types.

`test/support/api_contract.ex` validates real controller responses and accepted
request bodies using JSV, including multipart client imports. Tests that deliberately
send forbidden extra fields can skip request validation while still checking the response.
`test/nila_web/api_contract_test.exs` fails if a React API route has no operation,
if a documented route disappears, or if operation IDs collide. Run it and the
workspace, review, checks, upload, Business and invitation controller suites after changes.

Downloads are opaque artifacts with media types and error/redirect responses;
OpenAPI does not describe each cell in a workbook or the statutory JSON format.
PDF PUTs to presigned storage URLs are an external storage protocol, not Phoenix
API routes. Native fetch, session/CSRF protection, cancellation, and TanStack Query
remain in place. Generated TypeScript is a compile-time contract, not runtime
validation of every browser response.

## Biome

Biome is pinned in devDependencies and configured in `biome.json` for frontend
source, tests and configuration. It understands Tailwind directives and excludes
generated API types. Phoenix/LiveView assets and build/test output are outside its scope.

Run from `frontend/`:

- `pnpm run lint`: report code issues without editing files.
- `pnpm run format:check`: report formatting differences without editing files.
- `pnpm run format`: apply formatting only; no lint fixes or import reordering.
- `pnpm run quality`: check formatting, lint and import organization without editing files.

Formatting is applied; run `format:check` before committing frontend changes.
Lint cleanup remains deferred. Lint and quality checks may report existing findings.
These commands are not part of `check`, `build`, or deployment yet.
Keep formatting changes separate from feature changes; inspect lint fixes individually.
