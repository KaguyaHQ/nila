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
> (ephemeral container disk + public path).

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
