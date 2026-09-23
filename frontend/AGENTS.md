# React sales migration slice

The user explicitly selected React + TypeScript + Vite + shadcn in this repository.
This directory uses shadcn React components backed by Base UI (not Radix), its neutral CSS theme, and lucide icons;
the root HEEx-only component, token, and bundle rules still apply to the existing
LiveView frontend, not this separately built React entry point.

- Sales summary, register, PDF intake, upload history and invoice review use real Phoenix data. Sample screens are development-only. Reuse the existing correction and check rules in Phoenix.
- GSTR-1 section details and export availability come from Phoenix. Workings Excel may be a draft; do not equate its availability with permission to download GSTR-1 JSON. Downloads must show server errors in the current screen.
- Month-check confirmations use the server's current evidence basis. A stale response requires a fresh review, never an automatic retry with a new basis. Unsupported or blocking findings cannot be dismissed.
- Clients, identity add/edit, and Excel import use real Phoenix data. GST/Tally connection management remains in LiveView.
- Migration scope is GST automation. Exclude banking, Tally workflows, and Winman Excel exports. Required outputs are GST workings Excel and GSTR-1 JSON.
- Purchases overview and source registers use Phoenix data. Purchase review and ITC decisions use Phoenix APIs with fresh evidence tokens. Import, source corrections and pairing remain explicit LiveView handoffs. GSTR-2B fetching and OTP connection stay in React. GSTR-3B stays in LiveView. Source document counts differ from grouped reconciliation items; matching never means claimed ITC. Preserve source tax, including credit-note signs and any legacy cess, without adding routine cess controls.
- Use shared components in `src/components/ui`, not copied control classes in pages.
- Before building a generic control, check the official shadcn Base UI registry. Use its existing component when it covers the interaction; keep custom code for Nila's data, routes and accounting behavior. Do not port LiveView DOM hooks when the React primitive already owns that behavior.
- Nila is a desktop application. Do not expand migration work into mobile navigation or mobile-specific layouts unless requested.
- Use React Router within migrated screens. Use normal same-origin links for screens still owned by LiveView.
- Do not claim an upload, review, export, or accounting decision was saved when it was not.
- Use TanStack `useMutation` for server writes: derive pending/errors from the mutation, update caches only from confirmed responses, and invalidate affected queries. Keep `retry: false` and `networkMode: "always"` so failed/offline saves require an explicit retry. Preserve request cancellation and synchronous duplicate-submit guards; local validation, upload progress and downloads may keep local state.
- Keep fixture facts in `src/data/sales.ts`, temporary PDF selections in the existing
  upload provider, and all business truth in Phoenix.
- Run `pnpm run build` and `pnpm test`; inspect rendered screens at desktop widths.
- Keep Playwright artifacts under `frontend/test-results/`. Prefer one test invocation with multiple workers. For independent concurrent runs, give every run a distinct child directory using `--output=test-results/<run>`; do not run against the parent concurrently or create sibling output folders.
- Vite assets ship inside the Phoenix release. Do not deploy or replace further LiveView routes outside the requested migration scope.
