# Nila

Nila is the AI accountant for Indian CA firms, starting with GST. A Phoenix + LiveView
monolith.

The loop: the firm dumps whatever the client sent (sales bills, purchase bills, the
portal's GSTR-2B), Nila extracts and reconciles it, drafts the returns, and flags what
needs a human. The accountant decides the exceptions, a senior signs off, someone files
on the portal and records the ARN. Phoenix owns business truth; humans approve
exceptions before anything commits.

## What's built

- **Intake** — documents arrive as dumps, one arrival at a time (main pile early,
  stragglers after the chase). Each dump extracts on its own; the month derives from
  the union. A new 2B replaces the old. Dumps landing on a signed return are held; on
  a filed return, pointed to the next open month.
- **GSTR-1** — sales bills → extracted invoices → validation issues → human
  confirm/correct → reviewed → signed → portal JSON → filed.
- **2B reconciliation** — purchase bills matched against GSTR-2B, exception queue with
  decision verbs (confirm/reject/pick-the-right-row/correct/accept-unmatched/dismiss),
  ITC position with per-credit block/allow.
- **GSTR-3B** — assembled from the signed GSTR-1 and the reconciliation; own sign-off
  and filed mark.
- **Certification** — per-artifact sign-offs freeze figures into snapshots; a signature
  is a wall (senior-only reopen, R1 reopen cascades to 3B); filed is immutable.
- **Screens** — Today (every client-month, grouped by who it's waiting on), the
  client-month workbench (one room: R1, purchases, 3B), Register (all-periods filed
  history), Clients, and intake. Chase drafts for clients who sent nothing.

Every human decision is an append-only, attributed resolution; every surface renders
through one workings projection so nothing drifts.

## Stack

- Phoenix 1.8, LiveView
- Ecto + PostgreSQL (source of truth)
- Oban (extraction and derivation jobs)
- Tailwind CSS + daisyUI ("moonlight" tokens, `docs/design/DESIGN.md`)
- Req/Jason for HTTP/JSON
- `Nila.Storage` — local disk in dev/test, private Cloudflare R2 in production

## Local setup

```bash
# dev.exs requires local PostgreSQL on localhost:5432.
mix setup
mix phx.server
```

Open http://localhost:4000.

```bash
mix test
mix ecto.reset
mix precommit
```

## Production object storage

Production uses the private `nila-documents` Cloudflare R2 bucket through the
S3-compatible API. Create an R2 API token with Object Read & Write permission, scope it
only to `nila-documents`, and leave public access and custom domains disabled. Object
Read & Write includes the read, upload, and delete operations Nila needs.

Set these only in the production runtime environment:

```env
R2_ENDPOINT=https://0b6491b35807b48232b57646af4e7eeb.r2.cloudflarestorage.com
R2_BUCKET=nila-documents
R2_ACCESS_KEY_ID=
R2_SECRET_ACCESS_KEY=
```

The normal test suite always uses `Nila.Storage.Local`. To explicitly run the live R2
put/get/metadata/delete smoke test, export the four variables above and run:

```bash
mix test --include r2_integration test/nila/storage/r2_integration_test.exs
```

## Layout

- `lib/nila/` — business contexts. `gst/` is the core: extraction, recon, flags,
  resolutions, sign-offs, dumps, returns. Plus accounts, orgs, clients, documents,
  workflows, audits, integrations, storage.
- `lib/nila_web/` — LiveViews and web plumbing.
- `docs/` — architecture, decisions, design system, PRD.

## Deliberately not built (yet)

Amendments (filed is immutable; the amendment tables for later periods don't exist),
cross-month ITC carry, QRMP, photo/image intake. Pulled by real usage, not pushed.
