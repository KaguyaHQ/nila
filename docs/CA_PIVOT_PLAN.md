# CA Pivot — Repo Extraction Plan

_Decision of record, 2026-06-21. The thesis moved from service-ops system-of-record
(this repo, built around dad's field-service business) to a **CA AI-labor engine**
(bank-statement classification + GSTR-2B reconciliation, sold to CA firms). This plan
extracts the reusable substrate into a clean new repo and leaves the dad-shaped product
surface behind._

## Decision

**New repo, seeded from substrate.** Not edit-in-place.

Reason: the dad-domain is welded in at the *schema* level (customers, sites, work_orders,
quotes, invoices, catalog, equipment — ~20 of 23 migrations). Editing in place drags that
vestigial schema through every future CA migration forever. A clean repo lets us carry the
genuinely portable plumbing and drop the rest. The seams are shallow (a deletion cascade, a
few FKs, some doc comments) — lifting is ~1-2 days, not a week.

**This repo is the archive.** It stays committed, fully working. Git history + the on-disk
tree preserve every quote/invoice/rate-card module verbatim. The "what if I need invoicing
in 3 years" optionality costs nothing — `git checkout` retrieves it. Do not keep it on life
support; it is cold storage, and cold storage is the right state.

## Tiered inventory

### Tier 1 — copy near-verbatim (clean substrate)

| Area | Files | Notes |
| --- | --- | --- |
| Schema base | `lib/nila.ex` (`Nila.Schema`, `Nila.LineKind` if generic), `lib/nila/repo.ex` (fetch/transact helpers) | Foundation. `LineKind` may be invoice-specific — check before copying. |
| Auth/accounts | `lib/nila/accounts.ex`, `accounts/{user,scope,policy,user_token,user_notifier}.ex`, `mailer.ex` | Standard phx.gen.auth. Clean. |
| Tenancy | `lib/nila/orgs.ex`, `orgs/{org,membership,entity}.ex` | **Strip**: org-deletion cascade (orgs.ex ~L232-265 deleting invoices/quotes/customers) and `has_many :quotes` in org.ex. `org_entities` carries invoice_prefix/next/padding — keep for now, CA firm still issues its own invoices. |
| Audit | `lib/nila/audits.ex`, `audits/audit_log.ex` | Generic. Clean. |
| Storage | `lib/nila/storage.ex`, `storage/local.ex` | Generic. Clean. |
| Crypto | `lib/nila/encrypted_string.ex`, `encrypted_map.ex` | Generic Ecto types. |
| **Extraction (crown jewel)** | `lib/nila/documents.ex`, `documents/{extractor,extractor/llama_extract,extractor/stub,artifact,document,import}.ex` | The messy-PDF→structured primitive. **Strip**: `belongs_to :quote` in document.ex; the Invoices doc-comment in documents.ex. This is the most valuable thing in the repo for CA — bank statements/PDFs are the input. |
| GST math | `lib/nila/gst.ex`, `gst/{state_codes,place_of_supply}.ex`, `gstin.ex` | Pure jurisdiction logic. **Strip**: Quotes/Invoices mentions in doc-comments only (no code coupling). |
| Workflow scaffolding | `lib/nila/workflows.ex`, `workflows/{run,step}.ex` | Generic Oban-backed step runner. Reminder_worker is invoice-collections-specific — leave it. |
| Integrations | `lib/nila/integrations.ex`, `integrations/{connection,connector,gmail,gmail_sync_worker,whatsapp,whatsapp_ingest_worker,stub}.ex` | Ingestion surface (email/whatsapp document intake). Generic enough to carry. |
| Infra | `mix.exs`, `mix.lock`, `config/*`, `.formatter.exs`, `Dockerfile`, `docker-compose.yml`, `.githooks`, `lib/nila/application.ex`, `lib/nila/release.ex`, `lib/nila/typst.ex`, `formatters.ex`, `fuzzy.ex`, `rate_limiter.ex` | Plumbing. `application.ex` children list is already minimal (Repo, Oban, PubSub, Endpoint) — copies clean. |
| Assistant | `lib/nila/assistant*.ex` | LLM client/tools/trace. Generic infra, likely reusable for the engine. Review on copy. |

### Tier 2 — pattern transfers, code does NOT (rewrite)

| Area | Why it doesn't copy |
| --- | --- |
| **Approvals / HITL** | `ApprovalRequest` is `belongs_to :invoice` + `belongs_to :approver_contact`, `validate_required([:invoice_id])`. The whole context is `build_request(%Invoice{})` → route to customer contact → buyer-accepts-invoice. For CA the unit is "AI classified this bank line, confidence low → route to a junior to review." **Same philosophy (produce → route uncertain → human → audit), different schema.** Rebuild `approval_requests`/`approval_events` around the classification/review unit. Keep the `Classifier`/`classifiers/sdc` *shape* (pluggable classifier behaviour) — that abstraction is reusable; the SDC classifier itself is not. |

### Tier 3 — leave behind (dad-shaped product surface)

Do **not** copy: `customers/*`, `quotes/*`, `invoices/*`, `catalog/*`, `equipment/*`,
`contacts/*`, and their web LiveViews (`quote_live/*`, `invoices_live`, `customers_live`,
`equipment_live`, `items_live`, `purchase_orders_live*`, `receivables_live`, `po_review`,
`job*_live`). Mine them for reference only when building the CA equivalents.

## Migrations — do NOT copy the files

The foundational migration `20260526184134_create_nila_core_tables.exs` interleaves substrate
and domain tables in one `change/0`. Copying + surgically editing it is error-prone.

**Instead: write one fresh consolidated migration** in the new repo creating only the
substrate tables:

- Keep: `users`, `users_tokens`, `orgs`, `org_entities`, `org_memberships`, `documents`,
  `document_artifacts`, `workflow_runs`, `workflow_steps`, `audit_logs`,
  `integration_connections`. (Plus Oban migration `20260526184133_add_oban_jobs.exs` — copy verbatim.)
- Drop: `customers`, `contacts`, `sites`, `work_orders`, `invoices`, `invoice_line_items`,
  `invoice_payments`, `work_order_events`, and all quote/catalog/equipment migrations.
- `documents` table: drop the `work_order_id` FK; keep `org_id`, `sha256`, `status`, storage refs.
- `approval_requests` / `approval_events`: do **not** port the old shape — design the CA
  review-unit schema fresh (Tier 2).
- The `add_extraction_timestamps_to_documents` migration folds into the consolidated one.

Net: start at ~2 clean migrations (Oban + substrate) instead of dragging 23.

## First CA-engine slice (what replaces the dad product)

The new product surface, built on the copied substrate:

1. **Ingest** — bank statement / PDF in (reuse `documents` + `extractor`/`llama_extract` +
   gmail/whatsapp intake).
2. **Classify** — each transaction → ledger category. New `Classifier` clause; emit a
   confidence per line.
3. **Route (calibration)** — high-confidence auto-applied; low-confidence → review queue
   (the rebuilt approvals/HITL unit). This is the trust bar — value = fraction auto-cleared.
4. **Reconcile** — GSTR-2B match (later; needs supplier-filing data, not in our docs).
5. **Output** — draft return / structured ledger the CA reviews and signs.

Build and test on **dad's business data first** (consent + ground truth), then validate
classification quality against CA Excel from the discovery sprint. Do not extract raw client
data from CAs to start.

## Execution checklist

- [ ] `mix phx.new nila_ca` (or fork-copy infra) — fresh tree, same Phoenix 1.8 stack.
- [ ] Copy Tier 1 files; strip the listed domain references (cascade, FKs, doc-comments).
- [ ] Write consolidated substrate migration + copy Oban migration.
- [ ] Rebuild approvals/HITL around the classification review-unit (Tier 2).
- [ ] Port `AGENTS.md`, design system (`docs/design/*`, `core_components.ex`, app.css/js) verbatim.
- [ ] Rewrite `docs/prd.md` + `docs/STRATEGY.md` for the CA thesis (current ones are Thesis A).
- [ ] `mix setup && mix test` green on substrate before building the engine slice.
- [ ] Keep this repo committed and untouched as the archive.

## Tradeoff accepted

New-repo costs a few hours re-deriving config/CI/auth wiring vs edit-in-place. Paid
deliberately to avoid carrying a customers/quotes/equipment schema through a multi-year CA
build. The portable half (extraction, tenancy, GST, audit, storage) is what's hard to
rebuild and it transfers; the easy half (config plumbing) is what we re-pay.
