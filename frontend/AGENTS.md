# React frontend

React + TypeScript, Vite, shadcn/Base UI, Tailwind and Lucide. Follow the
[root scope](../AGENTS.md); product details live in
[purchase review](../docs/purchase-review.md) and
[Business invoicing](../docs/business-invoicing.md).

## Implementation

- Reuse `src/components/ui` and shared tokens. Add or refresh shared controls with
  the shadcn CLI from `frontend/`; do not copy components from another shadcn style
  or registry. Nila is desktop-first; no mobile work unless requested.
- Use TanStack Router with typed routes/search, and TanStack Query for server data.
  Use normal links for downloads and static pages; show download errors in the current screen.
- Use `RecordTableRow` with a visible `RecordTableLink` when a row opens a record.
  Keep other row controls independent; use ordinary rows for breakdowns and management tables.
- Use `useMutation` for writes with `retry: false` and `networkMode: "always"`.
  Derive pending/errors from it, guard duplicate submits, preserve cancellation,
  and invalidate affected caches after confirmed saves. Keep temporary PDF selections
  in the existing upload provider.
- Phoenix owns rules, validation, export readiness and evidence tokens. Never silently
  retry a stale confirmation with fresh evidence; require another review. Draft Excel
  availability does not imply GSTR-1 JSON readiness; reconciliation does not imply claimed ITC.
- Preserve source tax signs and values. Sample data is development-only. Retired import
  and GSTR-3B screens must not return merely because their backend code remains.

## Validation

- Run affected specs locally: `pnpm exec playwright test tests/sales-invoice.spec.ts`.
  Inspect the affected UI at desktop widths. Leave the full suite to CI unless explicitly
  requested or investigating a suite-wide failure.
- One local browser test run at a time, at most two workers. Check for an existing
  Playwright runner before starting; coordinate or wait. Separate output folders do not
  prevent resource contention.
- Use `pnpm run check` during development. Build once for combined changes before
  handoff, or for asset/build/public-page changes; each agent should not repeat the build.
- Keep artifacts in `frontend/test-results/`. Verify your runner exits; investigate leftover
  browsers without killing the user's browser or another agent's run.

## Public pages and deployment

- `src/public/` renders to HTML at build time. Public and error pages must work without
  JavaScript; error pages must also work without a database. Build before backend
  public-page tests. Keep legal wording unchanged unless requested.
- Vite assets ship in the Phoenix release. No deployment without explicit authorization.
