# Architecture

_Runtime, contexts, and the state principle for the AI accountant. See
`docs/prd.md` for product intent and the GST wedge._

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
- `Nila.Orgs` — tenancy: orgs, entities, and memberships (a CA firm and
  the client entities it files for).
- `Nila.Clients` — the firm's clients: the entities whose compliance work
  Nila drafts. `match_hints` accumulates known payer identities so
  confirmed bank-credit matches auto-resolve next time.
- `Nila.Documents` — uploaded documents and extracted/reviewed artifacts;
  the messy-PDF→structured extractor is the crown jewel of the substrate.
- `Nila.Gst` — the GST engine. Purchase reconciliation against the portal's
  GSTR-2B (`recon` — a "flag, don't guess" matching ladder), validation
  `flags`, the purchase `register`, `gstr2b` parsing, `month_pack` brief
  assembly, and `client_months` persistence (a client's worked month stored
  as JSON blobs, org-scoped). Plus pure jurisdiction helpers
  (intra/inter-state treatment, tax split, `gstin`/`state_codes`/`place_of_supply`).
- `Nila.Integrations` — external connectors (Gmail, WhatsApp). Adapters
  are stateless; they never write business state.
- `Nila.Audits` — append-only audit records across every state transition.

Frozen substrate — built for the earlier assistant/generic-workflow
direction, kept but not the current path (see `prd.md` §6):

- `Nila.Banking` — bank-statement spine: accounts and structured
  transactions projected from statement extractions. Money is integer paise.
  Reactivates later for full-bookkeeping clients.
- `Nila.Workflows` — Oban-backed generic workflow runs and steps. The GST
  month lifecycle is likely to get its own `client_month` state machine
  rather than this abstract Run/Step engine.
- `Nila.Assistant` — server-side tool-use loop against an
  OpenAI-compatible endpoint, scoped by org.

The engine's brain (`recon`/`flags`/`month_pack`) is validated end-to-end on
a real filed month; the review surface is built on top (see below).

## State principle

Processors and external adapters produce structured artifacts. They do not
own business state. Phoenix contexts validate, review, audit, and commit
every state transition. The human is in the loop for anything that lands
as `needs_review` or `pending_review`.

## Processing contract

External document processors satisfy a fixed interface. Nila sends a document
reference, metadata, and requested artifact kinds; the processor reads bytes
via a controlled storage URL or receives them directly, and returns structured
artifacts only:

```json
{
  "kind": "bank_statement_extraction",
  "version": 1,
  "data": {
    "account_number": "XXXX1234",
    "period_start": "2026-05-01",
    "period_end": "2026-05-31",
    "transactions": [
      {
        "date": "2026-05-06",
        "narration": "UPI/EXAMPLE TRADERS/...",
        "amount": "12500.00",
        "direction": "credit"
      }
    ]
  },
  "confidence": {
    "transactions.0.amount": 0.98,
    "transactions.0.direction": 0.91
  },
  "exceptions": []
}
```

Rules: processors never write business state; Phoenix stores returned artifacts
as `pending_review`; humans approve or reject exceptions; approved artifacts can
trigger workflow steps and audited state transitions.

## Web layer

- `lib/nila_web/` — controllers, LiveViews, components.
- `Layouts.app/1` owns the global shell, responsive gutters, left rail, and
  page header; `Layouts.settings/1` adds settings navigation within that shell.
- `NilaWeb.Gst.MonthLive` (`/gst/:client_id/:period`) is the product surface: the
  client-month workbench — a state strip (who the month waits on), the GSTR-1
  section (invoices, issues, review/sign-off/filed arc), the purchase register
  (2B recon, tap-a-row → the scanned bill via tenant-isolated evidence
  routes), and the assembled GSTR-3B with its own certification arc.
- `/today` (`TodayLive` over `Nila.Gst.WorkQueue`) is the front door: one row per
  client-month worth attention, sectioned by blocking state (to file / needs
  you / waiting on client / waiting on senior / done).

## Where to read next

- `decisions.md` — system-level decisions (Postgres, Oban, monolith, the
  R2 storage adapter design).
- `design/DESIGN.md` — brand, layout contracts, principles, and the moonlight system.
- `prd.md` — product intent: why/who, the GST wedge, goals and non-goals.
