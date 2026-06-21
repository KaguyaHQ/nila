# Architecture

> **Status (2026-06-21).** This document still describes the archived field-service
> (ops) domain. The runtime shape below — Phoenix 1.8 monolith, supervision tree,
> Postgres-as-truth — remains accurate, but the business contexts it details
> (customers, quotes, invoices, jobs) have been removed in the CA pivot. Pending a
> rewrite for the CA engine; see `docs/CA_PIVOT_PLAN.md` and `docs/prd.md`.

Nila is a Phoenix 1.8 monolith. The application shell, business contexts,
background jobs, and audit trail live in one OTP application. Postgres is
the source of truth; no Redis, Kafka, or external task queue.

## Runtime

- Phoenix + LiveView 1.1 serves the product UI (Bandit adapter).
- Ecto writes durable state to Postgres.
- Oban stores and executes jobs in Postgres-backed queues.
- `Phoenix.PubSub` (`Nila.PubSub`) carries real-time updates to LiveViews.
- `Nila.Storage` abstracts blob storage behind a behaviour
  (`put / get / delete / url`). `Local` adapter today; `S3` on Cloudflare
  R2 is designed but not built (see `decisions.md`).
- `Nila.EncryptedMap` is the Ecto type for at-rest credential encryption
  (used by `Integrations.Connection.credentials`).

## Domain boundaries

- `Nila.Accounts` — user identity.
- `Nila.Orgs` — tenancy: orgs and memberships.
- `Nila.Documents` — uploaded documents and extracted/reviewed artifacts.
- `Nila.Operations` — receivables ledger: the `Operation` primitive and
  its status pipeline, with append-only `Event` rows for transitions and
  follow-ups. Money is integer paise.
- `Nila.Workflows` — workflow runs and steps (invoicegen).
- `Nila.Approvals` — `ApprovalRequest`, per-OEM state machines, reply
  classification, cadence. SDC for Philips first; generic enough for the
  Siemens GRN chain and Elekta revision cycle.
- `Nila.Contacts` — OEM approver directory and site-to-region routing.
- `Nila.Integrations` — external connectors (Gmail, WhatsApp). Adapters
  are stateless; they never write business state.
- `Nila.Audits` — append-only audit records across every state transition.

## State principle

Processors and external adapters produce structured artifacts. They do not
own business state. Phoenix contexts validate, review, audit, and commit
every state transition. The human is in the loop for anything that lands
as `needs_review` or `pending_review`.

## Web layer

- `lib/nila_web/` — controllers, LiveViews, components.
- `Layouts.app/1` hosts the global shell (left rail, page header) per
  `docs/design/layout.md`.
- `/today` is the single list-detail cockpit for queue-shaped work (document
  review, acceptance chase, receivable follow-up, all actioned from its detail
  pane); record-management pages use Ramp-style tables and tabs (`/receivables`,
  future `/invoices`, `/documents` archive).

## Where to read next

- `decisions.md` — system-level decisions (Postgres, Oban, monolith, the
  R2 storage adapter design).
- `design/` — UI architecture decisions, starting with `layout.md`.
- `plans/` — feature implementation plans, with status headers.
- `processing_contract.md` — the contract for document processors.
- `prd.md` — product intent: why/who, the bet, goals and non-goals.
