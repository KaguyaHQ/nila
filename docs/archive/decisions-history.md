# Historical system decisions

Snapshot before the September 11 documentation cleanup. Some designs and module
names below are retired. Use [the current decisions](../decisions.md) for current work.

# Decisions

## Phoenix Monolith First

Nila starts as a Phoenix monolith because the first product is workflow-heavy, review-heavy, and audit-heavy. Keeping UI, jobs, and state transitions together reduces coordination overhead.

## Postgres as Source of Truth

Postgres stores organizations and users, clients, intake dumps and extraction
attempts, sales and purchase months, correction and review events, filing records,
and Oban jobs. Business state belongs in these records, not in a separate agent
state store.

## Oban for Workflows

Oban is used for durable jobs and reminders. Workflow business state remains in Nila tables; Oban is execution infrastructure.

## Storage Behind a Behaviour

Development and test use local disk; production uses private Cloudflare R2.
`Nila.Storage` keeps upload and evidence code independent of the adapter.

## Production Document Storage

`config/runtime.exs` selects `Nila.Storage.R2`. Uploaded documents and generated
evidence use object keys through `Nila.Storage`; they do not depend on a
container's local disk. The R2 adapter uses ExAws through `Nila.Storage.ExAwsClient`.

`url/2` supplies short-lived signed downloads, and `presign_put/2` lets the browser
upload directly. The adapter limits signed URL lifetimes to five minutes.
Controllers may also read evidence through `Storage.get/2` after checking access.

Intake owns source-file keys and the connection between dumps, saved invoice
artifacts, and evidence. The old generic document-table and content-hash design
no longer describes this path. See `lib/nila/storage.ex`, `lib/nila/storage/r2.ex`,
and `lib/nila/gst/intake/` for the current contracts.

## No Docling Integration Yet

Docling is expected processing infrastructure, but it is not wired in this scaffold. The integration boundary exists so the service can be added once the document-processing contract is proven.

## Ingestion: Manual Capture First, Inbox Watching Deferred

> Status: scope decision, 2026-06-01, made pre-pivot for the field-service MVP
> (§-references point at the archived `nila-ops` discovery docs). The reasoning
> survives the pivot: the CA engine's inputs are bank statements a human uploads
> or forwards monthly, which is even more batch-shaped than PO capture was.

The magic is **killing re-typing**, and that alone clears the bar. The
original user retyped invoices across systems and hand-forwarded GST data
between seven uncoordinated inboxes. Remove the retyping and the reward is
already "magical"; nothing else has to be automated to justify the product.

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
real document, there is no personal mail (matrimony threads, etc.) to filter and
no tokens burned classifying junk. Automatic watching would reintroduce that
filtering work; manual capture removes it by construction. The connector's
`has:attachment` default + blanket document typing only become a real token
risk once watching is on — another reason to defer.

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

Neither pattern is currently load-bearing in Nila; the entity-plus-audit-log
shape that used to be written as `Multi` is expressed more directly with
`transact` + `with` + `insert!`.

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

## Frozen Generic Substrate Retired

> Status: cleanup, 2026-07-22. Recovery point: commit `b48071e`
> ("retire frozen generic substrate the GST engine outgrew"). Full working
> versions also live in the archived `nila-ops` repo.

Four contexts carried over from the pre-pivot scaffold were deleted because the
live GST product had **empirically refuted** them — it reified each one
domain-specifically and never called the generic version. Recorded here so the
knowledge (that they existed, why they went, and when to revive) lives in a
decision, not as dead code future readers have to excavate.

Removed, and what replaced each:

- **`Nila.Workflows`** (`workflow_runs`/`workflow_steps`) — a stillborn
  Oban-backed Run/Step engine that never had a caller in either repo.
  `Gst.Intake` reifies the same shape: `Dump` (the run), `DumpWorker` (the
  driver), `ExtractionAttempt` (the audited step).
- **`Nila.Documents` + `Nila.Audits`** — the generic HITL document-extraction
  engine (Document/Artifact review lifecycle) plus its generic audit log. Wrong
  altitude: it generalized *meaning* (status machines, review gates, versioned
  artifacts) where meaning is domain-specific, while the truly-generic mechanical
  layer (`Nila.Storage`) was already factored out beside it. Superseded by
  `Gst.Intake` + `Gst.Filing.Signoffs`.
- **`Nila.Banking`** (`bank_accounts`/`bank_transactions`) — built for the
  abandoned bank-statement-classification thesis. The context itself was clean and
  standalone, but its only data-entry path was the Documents-coupled
  `BankStatementExtractionWorker`, and nothing live called it.

Dropped tables: `workflow_runs`, `workflow_steps`, `documents`,
`document_artifacts`, `audit_logs`, `bank_accounts`, `bank_transactions`
(migrations `20260722155241`, `20260722165125`; both irreversible by design).

**Kept:** the `Nila.Assistant` harness — the tool-use loop, SSE streaming, and
trace narration (~900 loc, a few days to rebuild). Its original "bring me the
document" use case died with the persona pivot (the customer is now a back-office
worker who fetches for themselves, not a principal), so its only tool — which
queried the retired `Documents` context — was dropped and the tool set moved to
a config-driven, empty-by-default registry (`config :nila, :assistant_tools`).
The harness is persona-neutral mechanism worth keeping for a future
junior-accountant assistant; wire real GST tools into the registry then.

**When to revive Banking:** TDS/ITR bank work (interest income, TDS
reconciliation) is a near-certain future need — but it is deferred per the PRD
("later, once GST earns trust") and, when it lands, should be **rebuilt fresh on
the `Extraction`/`Intake` pattern**, not reverted as-was. The old shape's
transaction-to-client matching was thesis-specific, and bank-statement *import*
is commoditizing (Suvit → Vyapar; Tally IRA now auto-imports) — treat bank data
as an integration/commodity input, not a bespoke capability to own. The moat is
the reconciliation + audit + trust surface, not the ingestion plumbing.
