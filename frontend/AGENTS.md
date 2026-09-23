# React frontend

The user explicitly selected React + TypeScript + Vite + shadcn in this repository.
This directory uses shadcn React components backed by Base UI (not Radix), its neutral CSS theme, and lucide icons;
the scoped rules in `lib/nila_web/AGENTS.md` and `assets/AGENTS.md` apply to the existing
static public pages, not this separately built React entry point.

- Sales summary, register, PDF intake, upload history and invoice review use real Phoenix data. Sample screens are development-only. Reuse the existing correction and check rules in Phoenix.
- GSTR-1 section details and export availability come from Phoenix. Workings Excel may be a draft; do not equate its availability with permission to download GSTR-1 JSON. Downloads must show server errors in the current screen.
- Month-check confirmations use the server's current evidence basis. A stale response requires a fresh review, never an automatic retry with a new basis. Unsupported or blocking findings cannot be dismissed.
- Clients, identity add/edit, Excel import and GST connection management use Phoenix APIs in React. Client GST verification only connects the account; month-specific fetching stays in Purchases. Tally is outside the React migration.
- GST migration scope is GST automation: workings Excel and GSTR-1 JSON. Banking, Tally workflows and Winman Excel exports remain outside that migration. Nila Business is separately approved work; follow the root scope and `docs/business-invoicing.md`.
- Purchases overview and source registers use Phoenix data. Purchase review and ITC decisions use Phoenix APIs with fresh evidence tokens. Sales/purchase Excel import UI is retired; backend import engines and existing data remain. The purchase worklist supports eligible bulk treatment; audited source corrections and suggested-pair decisions stay in React review. GSTR-2B fetching and OTP connection stay in React. The old GSTR-3B screen is retired; backend calculations remain. Source document counts differ from grouped reconciliation items; matching never means claimed ITC. Preserve source tax, including credit-note signs and any legacy cess, without adding routine cess controls.
- Use shared components in `src/components/ui`, not copied control classes in pages.
- For tables whose rows open a record, use `RecordTableRow` with one visible `RecordTableLink` inside it. The link owns the destination and keyboard access; other controls keep their actions. Keep breakdowns and multi-action management rows as ordinary `TableRow`s.
- Before building a generic control, check the official shadcn Base UI registry. Use its existing component when it covers the interaction; keep custom code for Nila's data, routes and accounting behavior. Do not port LiveView DOM hooks when the React primitive already owns that behavior.
- Nila is a desktop application. Do not expand migration work into mobile navigation or mobile-specific layouts unless requested.
- Use TanStack Router within migrated screens. Keep route/search contracts typed; TanStack Query owns server-data fetching and caching. Use normal same-origin links for downloads and static public pages.
- Do not claim an upload, review, export, or accounting decision was saved when it was not.
- Use TanStack `useMutation` for server writes: derive pending/errors from the mutation, update caches only from confirmed responses, and invalidate affected queries. Keep `retry: false` and `networkMode: "always"` so failed/offline saves require an explicit retry. Preserve request cancellation and synchronous duplicate-submit guards; local validation, upload progress and downloads may keep local state.
- Keep fixture facts in `src/data/sales.ts`, temporary PDF selections in the existing
  upload provider, and all business truth in Phoenix.
- Run `pnpm run build` and `pnpm test`; inspect rendered screens at desktop widths.
- Keep Playwright artifacts under `frontend/test-results/`. Prefer one test invocation with multiple workers. For independent concurrent runs, give every run a distinct child directory using `--output=test-results/<run>`; do not run against the parent concurrently or create sibling output folders.
- Vite assets ship inside the Phoenix release. Do not deploy without explicit authorization.
