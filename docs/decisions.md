# Decisions

## Phoenix Monolith First

Nila starts as a Phoenix monolith because the first product is workflow-heavy, review-heavy, and audit-heavy. Keeping UI, jobs, and state transitions together reduces coordination overhead.

## Postgres as Source of Truth

Postgres stores organizations, users, documents, artifacts, workflows, audit logs, and Oban jobs. Redis, Kafka, Celery, and separate agent state stores are intentionally excluded from the scaffold.

## Oban for Workflows

Oban is used for durable jobs and reminders. Workflow business state remains in Nila tables; Oban is execution infrastructure.

## Storage Behind a Behaviour

Development and test use local disk under `priv/static/uploads/`. The storage boundary allows later production adapters without changing document logic.

## Production Document Storage (planned)

> Status: designed, not implemented. Prod currently mis-uses `Nila.Storage.Local`
> (ephemeral container disk + public path). See `docs/TODO.md`.

The `Nila.Storage` behaviour (`put/get/delete/url`) is the right seam — documents
and workflows only ever see a `storage_key`, never a path or bucket. The
production design adds an adapter, not a refactor.

**Adapter — `Nila.Storage.S3` on Cloudflare R2.** Object storage, not a host
volume. Chosen over a mounted volume because documents must be durable
independent of the box. Reuse the `ex_aws` + `ExAws.Request.Req` client kaguya
already proved against R2. Config is per-env in `runtime.exs`: `Local` for
dev/test, `S3` for prod — no change at the call sites.

**Private bucket, presigned access.** Tax documents are sensitive: the bucket is
private and never fronted by a public path. `url/2` returns a **short-TTL
presigned GET** (e.g. 5 min) rather than a static path — this is the one
behavioural difference from `Local`, and the reason `url` takes `opts`
(`expires_in`). Downloads never proxy bytes through the app.

**Keys are content-addressed and org-scoped:**

    orgs/<org_id>/<sha256[0..1]>/<sha256>

`sha256` keying gives free dedup (it already backs the
`unique_index(:documents, [:org_id, :sha256])`); the org prefix keeps a tenant's
objects together for lifecycle rules. `filename`/`content_type` stay in Postgres
(the `documents` row), so the object store holds only opaque bytes.

**Uploads.** Start with server-side `Storage.put/3` (LiveView upload → app →
R2) for simplicity and server-side sha256/scan hooks. Move to direct
presigned-PUT only if/when large files make app-proxying a bottleneck; add a
`presigned_put/2` callback to the behaviour at that point — not before.

**Artifacts.** `document_artifacts.data` (jsonb) stays in Postgres for small
structured results. Large binary artifacts (rendered PDFs, OCR layers) use the
same `Storage` behaviour with a key like `orgs/<org_id>/artifacts/<doc>/<kind>/<v>`.

## No Docling Integration Yet

Docling is expected processing infrastructure, but it is not wired in this scaffold. The integration boundary exists so the service can be added once the document-processing contract is proven.

## Ingestion: Manual Capture First, Inbox Watching Deferred (MVP)

> Status: scope decision, 2026-06-01. Scopes **inbound document ingestion**.
> Does not touch approval-reply polling (`ReplyPollWorker`), which stays — it is
> narrow, thread-scoped, and already shipped.

The MVP magic is **killing invoice re-typing**, and that alone clears the bar.
The family retypes invoices across systems, sends them from the wrong account,
and hand-forwards GST data between seven uncoordinated inboxes today (discovery
§2, §14.2). Remove the retyping and the reward is already "magical"; nothing
else has to be automated to justify the product.

**Retrieval is the reward, and it is free.** Once a document's data is on Nila,
Nila *is* the index. So cross-inbox **search** is explicitly not an MVP feature:
we do not preserve the searchability of the seven Gmails, we replace the need
for it.

**Therefore MVP ingestion is the cheapest *manual* capture, not automatic
watching.** Shipped or near-free today: upload the PO PDF (`Documents.Import`
already turns bytes into a document + extraction), or the single-inbox "Sync
now" button that enqueues `GmailSyncWorker` (`connectors_live.ex`,
`operations_live.ex`). A forward-to-a-Nila-address inbox is the next cheapest
manual option if upload friction shows up. Explicitly **deferred**:

- **Automatic multi-inbox watching** — a cron fanning `GmailSyncWorker` across
  every active connection. (Note today's `ReplyPollWorker` uses
  `first_active_connection` and is single-inbox; real watching would have to be
  multi-inbox per §2/§14.2 — more reason it is not a casual add.)
- **Gmail push** (`users.watch` + Pub/Sub) — buys seconds-of-latency we do not
  need for back-office paperwork measured in hours, at the cost of a Pub/Sub
  topic, a public webhook, and `watch` channels that expire weekly (×7 inboxes).

**Why this is the right cut, not laziness.** The trap is treating "get the data
in" like a university entrance exam: grind once, then coast. Document capture is
not a one-time gate — POs arrive forever. So the principle is two-sided: a user
*will* do a trivial recurring action for a large reward, **but the action has to
stay one step.** That rules out *both* over-building (do not make them run
manual syncs or stand up watching infra) and over-cutting (do not make them log
into seven inboxes to find the PO). One drag-drop, or one forward, per PO.

**Free bonus: the noise problem disappears.** Because a human only ever feeds a
real PO, there is no personal mail (matrimony threads, etc.) to filter and no
tokens burned classifying junk. Automatic watching would reintroduce that
filtering work; manual capture removes it by construction. The connector's
`has:attachment` default + blanket `purchase_order` typing only become a real
token risk once watching is on — another reason to defer.

Revisit watching only when "I am tired of forwarding" is an *observed* complaint
from a real user, not an anticipated one.

## Transactional Code

> Status: convention adopted 2026-05-28. The cleanup plan is complete; keep
> this section as the durable convention.

Default to `Repo.transact(fn -> ... end)` (Ecto 3.13+) wrapping a `with` chain.
Reach for `Ecto.Multi` only when its specific affordances are load-bearing.

### Why `transact` over `Multi`

`Ecto.Multi` predates the `{:ok, _} | {:error, _}` + `with` idiom (both landed
in 2016). It became the default because the alternative at the time was
`Repo.transaction(fn -> ... end)`, which used exceptions for rollback and made
flow inside the callback awkward. `Repo.transact/2` (shipped in Ecto 3.13, June
2025) removes that awkwardness: the callback returns a tagged tuple, rollback
is automatic on `{:error, _}`, and the body is plain Elixir.

The arguments against `Multi` as the default:

1. **Two control-flow vocabularies.** Outside transactions we compose steps
   with `with`. Inside `Multi`, the same logical shape becomes a chain of named
   steps with callback maps. The reader has to context-switch at the
   transaction boundary even though the underlying intent is identical.

2. **`Multi.insert` flattens an intent distinction.** A failed primary write
   (user, invoice, operation) is recoverable and routes back to the caller. A
   failed audit-log or event-row write is a bug; the caller cannot fix it and
   we want to crash. With `Multi.insert` both look the same on the page.
   Inside a `with` chain the distinction reads off the syntax directly:
   `{:ok, x} <- Repo.insert(...)` versus `Repo.insert!(...)`.

3. **The context map is unsafe and costly.** Step name typos
   (`%{useer: u}`) compile fine; Dialyzer cannot track types through it; and
   every prior step's result stays reachable for GC until the transaction ends,
   which becomes real memory pressure on long flows with wide rows. Plain
   variables in a `with` chain give compile-time checks, types, and normal
   reachability.

4. **Step names usually exist for routing, not information.** When the caller
   only uses the step name to choose which error branch to render, the name is
   noise. The same code smell appears as the tagged-`with` antipattern
   (`with {:step1, {:ok, x}} <- {:step1, ...}`). In both cases the fix is to
   push the gnarly logic into a private function that returns a flat tagged
   tuple and let the outer `with` stay readable.

### Where `Multi` is still right

Keep `Multi` for:

- **Dynamic step composition.** A pipeline built in a loop, or whose shape
  depends on runtime config (e.g. building a Multi from a list of records, or
  conditionally appending steps), is genuinely cleaner with `Multi` than with
  branching `with` chains.
- **Caller needs `{:error, step_name, value, changes_so_far}`.** If the caller
  switches on which step failed and uses the partial-changes map, that's a
  real use of `Multi`'s shape, not incidental.

Neither pattern is currently load-bearing in Nila. Today's `Multi` usage in
`approvals.ex`, `operations.ex`, `invoices.ex`, and `documents.ex` is the
entity-plus-audit-log shape that `transact` + `with` + `insert!` expresses
more directly.

### Reads compose with `fetch`

Ecto ships `Repo.get/2` (returns `nil`) and `Repo.get!/2` (raises). Neither
composes into a `with` chain that lives inside a `transact` callback. Add
`fetch`-style helpers to `Nila.Repo` returning
`{:ok, row} | {:error, :not_found}`, mirroring `Map.fetch/2` and
`System.fetch_env/2`. A missing row when the caller expected one is a branch,
not a panic; the `:not_found` error is a normal value that propagates through
`with` and out of `transact` cleanly.

### Rollback is normal flow, not an exception

Inside a `transact` callback:

- `{:ok, value}` commits.
- `{:error, reason}` rolls back; `reason` is returned to the caller as
  `{:error, reason}` from `transact`.
- An exception still aborts the transaction (Postgres marks the connection as
  poisoned), so `Repo.insert!` inside the callback works exactly as expected
  for must-succeed writes.

Do not nest `transact` calls or call `Repo.transaction` inside a `transact`
callback. Savepoint semantics have surprised the Ecto team before (Ecto 1 to
2 transition); we have no concrete need that justifies introducing them here.

## Customer = OEM, not the hospital

> Status: decision recorded 2026-06-06. Names the role of `Nila.Customers.Customer`
> and the Quote/Invoice `customer` association.

A `customer` is the **commercial counterparty that pays us**, the receivables
party. It is not the place the work happens. In the first vertical that party is
almost always the **OEM** (Philips, Siemens, Elekta, GE Healthcare): the family
is a service partner who bills the OEM, and the OEM pays. The hospital where the
work physically happens is a `Nila.Customers.Site`, linked at the quote stage. A
*direct sale*, where the hospital pays us itself, is the exception: there the
hospital is both the customer and its own site.

The schema already encodes this, which is why the fields read as OEM-shaped:
`Nila.Customers.seed_default_customer_workflows/1` seeds the OEMs as customer
rows; `workflow` is the per-OEM approval state machine; `gstins` is a
`state => gstin` map because an OEM holds many state registrations;
`portal_vendor_ids` (DVIMS, iTracer) are vendor-portal IDs that hospitals do not
have; and `tags` carries the OEM discriminator used to route approvals.

**What this corrects.** The name "Customer" carried no role signpost, so the
first Philips quote importer attributed each quote's customer to its *delivery
hospital*, exploding one OEM into ~200 duplicate customers and discarding the
billing relationship. The fix is two-part: signpost the role (the `Customer`
`@moduledoc` and this entry), and give the quote a place to keep the site so the
correct attribution loses no data. `quotes` gained nullable `site_name` /
`site_location` columns, so the quote (the lifecycle spine — see "Quote is the
lifecycle spine" below) holds the site directly. The canonical importer now attributes the quote
to its bill-to party and records the hospital in `site_name`; the historical
Philips data was re-imported under this model (`scripts/philips_quotes/reimport.exs`).

## Quote is the lifecycle spine; PO keeps the name "PO"

> Status: decision recorded 2026-06-11. Drives the `docs/.plans/quote-spine.md`
> migration that makes the quote the single spine and drops `work_orders`.

The spine is whichever object is born at the start of the lifecycle, is
one-per-unit-of-work, and is authored by us. For Nila's MVP that is the
**quote** — the lifecycle starts at the quote, not at a dispatch or service
request. The `work_orders` table is being dropped (not soft-deprecated): it was
born second (at `po_received`), is PO-derived, and a dead table left "for later"
is how a second spine grows back. A work-order object earns existence only the
day a vertical's lifecycle starts *earlier* than the quote (dispatch / service
requests / PMS), rebuilt cleanly then via backfill.

The rationale and the empirical state that forced this (two disconnected spines —
`accept_and_convert` made a PO-less invoice while `PoInvoice` spawned a
quote-less work order, so the MVP's named flow "PO arrives → find the
quote → invoice it" had no home) live in the plan. The ratified contract:
`quote_id` is a real FK on invoices (no `settings["quote_id"]` blob); recording a
PO is a `sent → won` quote transition; the invoice is born at the explicit
`won → invoiced` act, not at acceptance; `paid` means summed-outstanding-zero
across child invoices; `org_id` is stamped on quotes; `report_pending` is an
optional gate, not a mandatory stop.

**Why the PO columns keep the name `po_*`.** The PO fields move onto the quote,
and the question came up whether to rename them to role-neutral
`authorization_*` so a future non-OEM vertical (an elevator AMC billing a housing
society off a WhatsApp confirmation, not a PO) reads naturally. Decision: **keep
`po_number` / `po_date` / `po_amount_paise`.** In Indian B2B this artifact is
called a PO — every OEM issues one, staff say "PO aaya kya?", and the invoice
prints a "P.O. No." field carrying the buyer's reference. `authorization_ref` is
a textbook word nobody in this domain speaks; naming the schema for it would be a
permanent translation layer maintained for a vertical we have not entered.

The argument for pre-renaming rested on a false asymmetry ("free now, expensive
later"): a Postgres `ALTER TABLE ... RENAME COLUMN` is a metadata-only operation,
effectively instant with or without data, and the code side is a find-replace. So
there is no cost reason to decide now what the second ring's authorization looks
like — decide then, with a real customer in front of us, at essentially the same
price. Intent is recorded in prose instead: **"`won` requires a recorded
authorization; today the only kind is a PO"** — which binds no schema. Renaming
or adding a `kind` discriminator stays a cheap, deferred move (rule of three).

## Asset register & renewal-first (recorded, gates schema)

> Status: finding recorded 2026-06-18 from `docs/discovery/chiller-renewal-session.md`.
> Not yet built. Gates whether an `Equipment`/asset schema and zone/card axes on
> `Catalog.ItemRate` enter scope.

The chiller renewal session exposed a primitive the MVP spine does not model. The
PRD spine is **quote-first** (`quote → won → invoiced → paid`, ~50 open quotes
hand-entered). The actual bulk of this business is **renewal-first**: ~993
installed Siemens machines across six states, each a standing object that
re-bills every April off a published rate contract. The "quote" on a renewal is a
formality the rate card generates; the unit of work is the *asset*, not a fresh
quote.

**The asset register is data; the price grid is not.** A chiller row is
`EID + serial + model + site + category + zone + card + contract_type`. That has
no backfill story (you cannot reconstruct "EID … is an outstation old-card
Essenza at this site" from anything else) — by `strategy.md` §7's backfill test,
build it. The 14-column year grid is a *derivation* off the rate contract (5
categories × 2 zones × 2 cards = 20 numbers); storing it imports the exact rot
the system of record exists to kill. **Store the asset, derive the price.**

**The schema is generic; the vertical lives in the values.** The asset is five
fields — a serviceable thing, at a site, of a category, on a contract, at a
derived rate — identical for an elevator, fire panel, or genset AMC. Portability
comes from keeping `category` / `zone` / `card` / `model` as *strings*, never
medical-specific columns (`magnetom_model`, `eid` as a typed field). The fear
that an asset register won't generalize is backwards: a register is the
highest-confidence shared primitive across the second ring (every AMC business
has one), and *not* having one is what fails to match any of them. The real trap
is vertical columns, not the table — guarded by `strategy.md` §7 ("vertical-ness
in data, not schema").

**The classification is the product, not a throwaway string.** `MAGNETOM
Sempra → Essenza → outstation → 28,474` is the whole job — every audit bug was a
broken instance of it. So the generic `category` column carries a *vertical
mapping* (`model → category`, per OEM) that is the moat: encode Siemens once,
every Siemens vendor inherits it (`strategy.md` §3.4), and each human correction
(`Free.Star = Ext MRI`) accrues to it. Schema portability and classification
value are different layers — the column generalizes, the mapping is medical and
is supposed to be.

**What this implies if built.** (a) a new `Equipment` table (generic five-field
shape, status field); (b) a `status` that makes out-of-contract machines a
*query* not a memory — the fix for the free-serviced-machine leak, moving truth
out of the owner's head; (c) zone (local/outstation) and card (old/new) axes on
`Catalog.ItemRate`, which today is keyed only `(item, customer, fiscal_year)` and
cannot represent the rate contract; (d) price as a derived lookup, never a stored
column. Migration from the six state files is a **one-time, human-reviewed
agent bootstrap** (assets + resolved category/zone/card, every uncertain row
flagged), not an import UI — onboarding is white-glove and the price grid is
never imported.

**Open: scope.** This is arguably past the quote-first MVP cutline. But the
chiller list *is* the real recurring business, so deferring the register leaves
the dominant workflow in Excel. Decision on whether it enters MVP or waits for
the renewal engine is deliberately left to the next planning pass — this entry
records the shape so it isn't re-derived.
