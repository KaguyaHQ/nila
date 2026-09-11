# Architecture

_The current runtime, code boundaries, and state principle. See `docs/prd.md` for
the product objective and `docs/decisions.md` for decisions and their reasoning._

Nila is a Phoenix and LiveView monolith. Postgres is the source of truth, and
Oban stores and runs background jobs in Postgres. There is no separate queue or
workflow service.

## Runtime

- Phoenix and LiveView serve the web application.
- Ecto reads and writes durable business state in Postgres.
- Oban runs extraction and background jobs; job records do not replace business state.
- Phoenix PubSub carries progress updates to LiveViews.
- `Nila.Storage` owns document and evidence blobs. Development and tests use local
  storage; production uses the private R2 adapter.
- `Nila.EncryptedMap` encrypts integration credentials at rest.

## Domain boundaries

- `Nila.Accounts`, `Nila.Orgs`, and `Nila.Clients` own identity, tenancy, and client
  records.
- `Nila.Gst.Intake` owns uploaded dumps, extraction attempts, source files, and
  evidence. `Nila.Gst.Extraction` turns processor artifacts into normalized facts.
- `Nila.Gst.Sales` owns outward invoices, GSTR-1 derivation, review decisions,
  corrections, sales months, and the accountant-facing workings output.
- `Nila.Gst.Purchase` owns purchase review and GSTR-2B reconciliation. It is an
  existing GST surface, not part of the current bills-to-workings wedge.
- `Nila.Gst.Filing` owns sign-offs and external handoff formats such as Winman and
  Tally. `Nila.Integrations` owns connector adapters such as WhatsApp.
- `Nila.Storage` owns the blob adapter boundary; business contexts decide what a
  stored object means.

## State principle

Processors and external adapters return structured artifacts. They do not commit
business state. Phoenix contexts validate facts, replay recorded human decisions,
and commit audited transitions. Unresolved exceptions stay visible until a human
resolves or confirms them.

The bills-to-workings path is:

```text
upload → intake dump → extraction → saved sales facts
       → corrections and review decisions → effective sales working → Excel
```

Sales code supplies prepared invoices to the workbook, GSTR-1 JSON, and Tally
builders. Each output owns its format requirements. The first product promise
is usable Excel workings; filing remains the firm's responsibility.

## Web layer

`lib/nila_web/` contains controllers, LiveViews, and shared components. The sales
month workspace is under `/gst/:client_id/:period/sales`; intake and batch review
are under `/sales-bills`, with a dedicated invoice viewer under the sales month.
Controllers enforce organisation-scoped reads
before serving workbook, JSON, or evidence downloads.

## Where to read next

- `docs/prd.md` — product objective, customer evidence, goals, and non-goals.
- `docs/decisions.md` — system decisions and their rationale.
- `lib/nila/gst/sales/README.md` — sales ownership and output boundaries.
- `lib/nila/gst/extraction/README.md` — extraction ownership and shared-fact rules.
- `docs/design/DESIGN.md` — UI principles and design-document routing.
