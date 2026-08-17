# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Conventions

Detailed Elixir, Phoenix, LiveView, Ecto, and HEEx coding rules live in `AGENTS.md` at the repo root. Read it before writing code — it is authoritative for this project. Key points worth surfacing:

- Use `Req` for HTTP requests (it's already a dependency). Do not add `httpoison`, `tesla`, or `httpc`.
- Run `mix precommit` when finished with a set of changes and fix anything it flags.
- This is Phoenix 1.8 with Tailwind v4 (no `tailwind.config.js`) and LiveView 1.1.

## UI / Design

`docs/design/DESIGN.md` is the UI router and invariant set — read it before editing `.heex` or components. Then read `docs/design/FRONTEND.md` for mechanical/token work, `docs/design/COMPOSITION.md` for screen design, or `docs/design/MARKETING.md` for public pages. `docs/design/TASTE.md` judges aesthetic calls. The system is **"moonlight"**: daisyUI v5 semantic tokens over a bespoke light-only palette. Exact token values live in `assets/css/app.css`.

- Use the moonlight tokens; never hard-code colors (`slate-*`, `bg-white`, raw hex). Parts of the interior still use legacy slate — that's drift to fix when you touch a page, not a pattern to copy.
- Build pages from the shared components in `lib/nila_web/components/` — one module per component (`card.ex`, `badge.ex`, `modal.ex`, `table.ex`, `evidence.ex`, …), all imported by `lib/nila_web.ex`'s `html_helpers`. Extract a new module when a pattern repeats rather than pasting class strings. That directory is the single source of truth for the look.
- Dropdowns & overlays — reach for the lightest tool that works, in this order. Form values (select, combobox): native daisyUI `<select>`; it submits correctly, needs zero JS, and can't drop a pre-filled value. Tooltips and simple menus (row "⋮" actions): daisyUI's CSS `tooltip` / popover-based `dropdown` — also no JS. Only build an owned JS component when a control genuinely needs interaction the platform can't give (e.g. a type-to-filter combobox), and when you do, server-render its `<input type="hidden">` so the value is present on first paint and testable. Do not vendor a component suite to style a `<select>` — that was tried and reverted; the engine's weight and form-integration seams cost more than they bought.

## Commands

```bash
mix setup              # install deps, create+migrate DB, build assets (run once)
mix phx.server         # start server at http://localhost:4000
iex -S mix phx.server  # start server inside IEx

mix test                       # runs ecto.create + ecto.migrate, then the suite
mix test test/path/to_test.exs # single file
mix test test/foo_test.exs:42  # single test by line
mix test --failed              # re-run only previously failed tests

mix precommit          # compile --warnings-as-errors, deps.unlock --unused, format, test

mix ecto.reset                          # drop + recreate + migrate + seed
mix ecto.gen.migration name_with_underscores  # always use this to create migrations
```

Dev-only routes (behind `:dev_routes`): LiveDashboard at `/dev/dashboard`, Swoosh mailbox preview at `/dev/mailbox`.

## Docs Fast Path

Canonical sources:

- Product intent (why/who, the GST wedge, goals, non-goals): `docs/prd.md`
- Runtime and domain shape: `docs/architecture.md`
- Architecture decisions: `docs/decisions.md`
- UI router/invariants: `docs/design/DESIGN.md`; scoped frontend, composition, marketing, and taste guidance lives beside it

Scratch/implementation plans go in `docs/.plans/` — gitignored, local-only. Not `docs/plans/` (that path is tracked).

## Architecture

Standard Phoenix umbrella-free layout split into a domain root (`Nila`) and web layer (`NilaWeb`):

- `lib/nila/` — business/domain code. `Nila.Repo` (Postgres via `ecto_sql`), `Nila.Mailer` (Swoosh). New contexts go here.
- `lib/nila_web/` — HTTP/LiveView layer. `NilaWeb.Endpoint` (Bandit adapter), `NilaWeb.Router`, controllers, and `components/` (one module per shared component, plus `layouts.ex`).
- `lib/nila_web.ex` — defines the `use NilaWeb, :controller | :live_view | :html | :router` macros; app-wide imports/aliases (e.g. `Layouts`) belong in its `html_helpers` block.
- `lib/nila/application.ex` — supervision tree: Telemetry → Repo → Oban → DNSCluster → `Phoenix.PubSub` (`Nila.PubSub`) → Endpoint.

Routing: `/` is the public marketing landing (`PageController`); the rest of the app sits behind a `:require_authenticated` pipeline (session auth, RBAC via `Nila.Accounts.Policy`), and signed-in users land on the `/today` cockpit (`TodayLive`, currently a placeholder). `/health` is a JSON probe used by the container healthcheck. Substrate contexts (accounts, orgs, documents + extractor, gst, audits, integrations), Oban wiring, and a pluggable `Nila.Storage` behaviour are in place. The current product is the **GST engine** (`Nila.Gst`: purchase reconciliation vs GSTR-2B, validation flags, register, `client_months` persistence) and its **review workspace** (`MonthLive` at `/gst/:client_id/:period` — the client-month workbench: GSTR-1, purchase register, and 3B on one page). The assistant (`Nila.Assistant`), generic workflows (`Nila.Workflows`), and banking (`Nila.Banking`) are frozen — built for an earlier direction, kept but not the current path. See `docs/prd.md`.

Deploys to a Hetzner box at `nila.tax` via GitHub Actions (`.github/workflows/deploy.yml`); see `hetzner/README.md`.
