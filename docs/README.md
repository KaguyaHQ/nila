# Nila Docs

The router for everything in `docs/`. Use this file to find the source of
truth, then open only the specific doc that answers your question.

If you are an agent, start with [`AGENT_MAP.md`](./AGENT_MAP.md). It gives
Claude a short read path by task so it does not need to scan the whole docs
folder.

## Top-level files

- [`AGENT_MAP.md`](./AGENT_MAP.md) — fastest route through the docs for
  coding agents. Read this first when deciding what context to load.
- [`prd.md`](./prd.md) — product **intent**: why Nila exists, who it's for,
  the bet, and the goals/non-goals. Not current state or backlog (those are
  the code and `TODO.md`). The single-page "what is Nila and why."
- [`architecture.md`](./architecture.md) — one-page system shape: runtime,
  domain contexts, state principle. Points into the deeper docs.
- [`decisions.md`](./decisions.md) — system-level decisions (Phoenix
  monolith, Postgres as source of truth, Oban, the R2 storage adapter
  design). Append-only over time.
- [`processing_contract.md`](./processing_contract.md) — the fixed
  interface document processors must satisfy. Read before adding any
  extractor or external processor.
- [`glossary.md`](./glossary.md) — domain terms. India tax/finance,
  OEM-workflow vocabulary (SDC, GRN, LAMC, PMS), Nila-internal terms.
- [`TODO.md`](./TODO.md) — the **MVP cutline**: the single ordered backlog
  of what's left to ship the MVP, across product and infra.

## Subfolders

- [`design/`](./design/) — UI architecture decisions, starting with
  [`design/layout.md`](./design/layout.md) (Ramp-style shell for record
  pages, Front/Superhuman-style cockpits for queue work, and how to choose
  between them).
- [`plans/`](./.plans/) — per-feature implementation plans, with status
  headers showing shipped / in-flight / deferred / planned. The folder
  README explains the per-plan shape and status conventions.
- [`discovery/`](./discovery/) — evergreen customer-workflow research,
  real artifact samples, domain knowledge. The input to plans; does not
  expire when a feature ships.
- [`runbooks/`](./runbooks/) — operational and debugging playbooks for
  shipped features (e.g. assistant latency). Symptom-titled, each one
  self-contained enough to reproduce outside the app.

## Where things go

Use this table when deciding where a new note belongs.

| If you want to…                                | Edit / add in        |
| ---------------------------------------------- | -------------------- |
| Capture a product-shaping fact about the user  | `discovery/`         |
| Plan a feature build                           | `plans/`             |
| Record a system-level decision and its reason  | `decisions.md`       |
| Decide UI architecture (layout, density, etc.) | `design/`            |
| Add a coding convention or Iron Law            | `AGENTS.md` (root)   |
| Define a domain term in one or two lines       | `glossary.md`        |
| Track any TODO (product or infra)              | `TODO.md`            |
| Capture a debug/diagnosis playbook             | `runbooks/`          |
| State product intent or a non-goal             | `prd.md`             |
| Record the as-built state                      | the code + the relevant plan |

If a doc grows to need more than this folder's structure can hold, give
it its own subfolder with a README following the [`design/`](./design/)
pattern.

## Conventions

- **Reasoning first, prescription second.** Every decision doc should
  explain *why* before *what*. The why is what lets future-you (or an
  agent) judge edge cases instead of pattern-matching blindly.
- **Status headers on plans.** Every file in `plans/` opens with one line
  saying shipped / in-flight / deferred / planned. See `plans/README.md`.
- **No em dashes** in user-facing copy. Hyphens or parentheses are fine.
- **Append, don't rewrite, decisions.** When a past decision is overridden,
  add a new entry and link back with `Supersedes:`. The reasoning trail
  matters more than tidiness.
- **No duplicate facts.** Pick one home and link from the others. If two
  docs both want to be the source of truth for the same fact, one of them
  is wrong.

## Outside `docs/`

- [`AGENTS.md`](../AGENTS.md) — authoritative coding conventions for
  Elixir, Phoenix, LiveView, Ecto, HEEx. Read before writing code.
- [`CLAUDE.md`](../CLAUDE.md) — Claude Code-specific repo guidance.
  Points at `AGENTS.md` for conventions and at `docs/` for the rest.
