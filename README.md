# Nila

Nila is a Phoenix + LiveView scaffold for workflow-heavy document back-office automation for Indian SMBs and CAs.

Phoenix owns business truth. Postgres is the source of truth. Oban runs background jobs. External processors may return structured artifacts later, but humans approve exceptions before Phoenix commits state.

## Stack

- Phoenix 1.8 and LiveView
- Ecto and PostgreSQL
- Oban for background jobs and workflow execution
- Tailwind CSS and daisyUI from the Phoenix default asset setup
- Req and Jason for HTTP/JSON infrastructure
- Local disk storage in dev/test behind `Nila.Storage`

## Local Setup

```bash
cp .env.example .env
docker compose up -d postgres
mix setup
mix phx.server
```

Open http://localhost:4000.

Useful commands:

```bash
mix test
mix ecto.reset
mix precommit
```

## Boundaries

- `lib/nila/` contains business contexts: accounts, orgs, documents, workflows, audits, integrations, and storage.
- `lib/nila_web/` contains Phoenix web and LiveView code.
- `priv/static/uploads/` is the local development upload root.
- `docs/` records architecture, decisions, and processing contracts.

Docling integration is intentionally not wired yet.
