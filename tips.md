# GSTR-1 productionization — handoff for Fable

> Scratch handoff, delete when step 5 lands. Written by the agent that did steps 1–4.
> Everything below is verified against the repo, not remembered.

## TL;DR

We moved the GSTR-1 ("R1", the outward sales return) engine **out of `scripts/` into
tested `lib/`** and gave it a body: extractor → worker → persisted aggregate. Four
commits, all green (`mix precommit`, 326 tests). What's left is **step 5: the human
review UI** (upload + month view + resolve exceptions). That's the last piece, and it's
the most duplicative — read the "Step 5" section before you copy-paste three LiveViews.

The engine, extractor, worker, and aggregate are done. **Step 5 blocks nothing** — not
engine iteration, not GSTR-3B (which already exists as `Nila.Gst.Gstr3b`). It's purely
the human surface for the dump→draft→**review** loop.

## Why this work exists

GSTR-1 reproduction was proven in an eval (`docs/.plans/2026-07-06-gstr1-eval.md`): Nila
extracts a scanned sales-bill packet, derives a portal-shaped GSTR-1 JSON, and reaches
the real filed return exactly after a human touches only flagged fields. **Proven on
Breeze (100% after review, 0 silent errors), lower on Caltech (53–70% raw, never
reviewed).** But the whole engine lived in `scripts/gstr1_eval_lib.exs` with **zero
tests**. `scripts/` is where you prove a schema once; it is not where a filing engine
lives. So we productionized it, mirroring exactly what the purchase side already did.

## The mirror (this is the key mental model)

Every GSTR-1 module is the **outward twin** of an existing purchase-side module. When in
doubt, open the purchase file and copy its shape. The purchase side is the reference
implementation for the sales side.

| Purchase side (built earlier) | Sales side (this work) | Status |
|---|---|---|
| `Nila.Gst.PurchaseBooks` (normalize) + engine | `Nila.Gst.Gstr1` (derive/validate/diff) | ✅ done, tested |
| `PurchaseExtractor` + `Stub` + `LlamaExtract` | `SalesExtractor` + `Stub` + `LlamaExtract` | ✅ done, tested |
| `ClientMonth` / `ClientMonths` | `SalesMonth` / `SalesMonths` | ✅ done, tested |
| `MonthWorker` (Oban) | `Gstr1Worker` (Oban) | ✅ done, tested |
| `Resolution` / `gst_resolutions` (append-only) | **reuse the same table**, new verbs | ⬜ step 5 |
| `GstUploadLive` | `Gstr1UploadLive` | ⬜ step 5 |
| `GstMonthLive` | `Gstr1MonthLive` | ⬜ step 5 |
| `GstExceptionsLive` (617 lines) | `Gstr1ExceptionsLive` | ⬜ step 5 |
| `GstEvidenceController` | reuse pattern (or param) | ⬜ step 5 |

## What's DONE (commits `9d58de7`, `753798f`, `c8d1774`, `8c883e2`)

**1. `lib/nila/gst/gstr1.ex` — the pure engine.** Ported from the script; no IO, no
network. Public surface: `normalize_invoice/1`, `validation_issues/1`, `flagged_fields/2`,
`apply_corrections/3`, `derive/2`, `diff/2`, `valid_gstin?/1`. The script
(`scripts/gstr1_eval_lib.exs`) is now a thin shim that `defdelegate`s to this — **one
brain, not two.** Tested in `test/nila/gst/gstr1_test.exs`: unit tests (poison-total
canary, sequence gaps, silent-error discipline, GSTIN checksum) + reproduction baselines
that replay the real filed returns and lock in current scores. The reproduction tests read
gitignored `tmp/eval/*/pages` artifacts and **skip on a cold checkout** (so CI won't fail
without the fixtures — but they DO run locally where the artifacts exist).

**2. `lib/nila/gst/sales_extractor.ex` (+ `sales_extractor/stub.ex`, `.../llama_extract.ex`).**
The swappable extractor. `Stub` returns deterministic offline pages (incl. the page-1
poison-total canary) for dev/test; `LlamaExtract` lifts the validated per-page flow +
sales schema from `scripts/extract_sales.exs`. Selected via
`Application.get_env(:nila, :sales_extractor, ...Stub)`. Config wired in `config.exs` +
`runtime.exs` — flips to LlamaExtract on `LLAMA_CLOUD_API_KEY`, same gate as purchases.

**3. `lib/nila/gst/sales_month.ex` + `sales_months.ex` + migration.** The persisted
aggregate. `sales_months` table: `org_id`, `client_id`, `period`, `state`, `invoices`,
`derived_gstr1`, `issues`, `summary`; unique `[client_id, period]`. Context copied near-
verbatim from `ClientMonths`: `upsert` (tenancy set on struct, never cast), org-scoped
`get_by_period`/`list_for_org`, `evidence_key`/`fetch_evidence` (path-traversal guard),
PubSub `subscribe`/`broadcast_progress`. Evidence key prefix is `gstr1/...` (purchase is
`gst/...`).

**4. `lib/nila/gst/gstr1_worker.ex` — the Oban job.** `PDF → SalesExtractor.extract →
Gstr1.normalize/validate/derive → store evidence → SalesMonths.upsert (state "worked")`.
Narrates stages over PubSub, terminal-fails on last attempt. **No GSTR-2B, no recon** —
outward filing has a single input. Enqueue args: `%{org_id, client_id, period, pdf_key}`.

> ⚠️ **One non-obvious decision in the worker.** `Gstr1.derive/2` takes a `filed` return
> as its 2nd arg (from the eval, where the filed return is ground truth). **In production
> there is no filed return — we're producing it.** So the worker synthesizes a minimal
> header from the **client's own GSTIN + the period** (`YYYY-MM` → portal `MMYYYY`).
> `derive/2` only reads `gstin`/`fp`/`fil_dt` off that header. Trust sits on the client
> record's GSTIN being correct. If you ever change `derive/2`'s signature, this is the
> caller to fix.

## What's LEFT — Step 5: the review UI

This is the only remaining piece. Three LiveViews + routes + evidence. **Read this whole
section before writing code** — the naive "copy three files" approach bakes in drift.

### The honest duplication read (per view)

- **`Gstr1UploadLive`** — ~90% a copy of `GstUploadLive`. Only diffs: **one** file input
  (no GSTR-2B), and it enqueues `Gstr1Worker` with `%{org_id, client_id, period, pdf_key}`
  (no `gstr2b_key`). Progress message tuple is `{:gstr1_month_progress, client_id, period,
  msg}` (worker already broadcasts this) vs purchase's `{:gst_month_progress, ...}`.
- **`Gstr1MonthLive`** — shell is shared (table + evidence modal), but **content is
  genuinely new**. Purchase shows 2B-recon buckets; sales shows the **derived GSTR-1 +
  validation issues + a downloadable portal-JSON** (the file an auditor uploads — that's
  the product output, and it already exists as `sales_month.derived_gstr1`). Add a
  download link/route that serves `Jason.encode!(derived_gstr1)`.
- **`Gstr1ExceptionsLive`** — the big one (`GstExceptionsLive` is 617 lines). **Reuse the
  machine, not the verbs.** The append-only `gst_resolutions` table + `Workings.materialize`
  replay pattern is reusable. But sales exceptions are **validation issues** (poison totals,
  GSTIN checksum failures, sequence gaps, lopsided CGST/SGST splits, furniture rows) — NOT
  2B pair-matching. So the verb vocabulary is new: think `correct_field`, `confirm_gap`
  (a sequence gap is a real cancellation), `reopen`. The issues already come out of
  `Gstr1.validation_issues/1` and are persisted in `sales_month.issues`.

### The fork you (Fable) should decide with the user first

The user explicitly flagged the duplication and did NOT want to blindly copy. Options
that were on the table (user declined to pick — so **ask them**):

1. **Skip step 5 for now** — engine is iterable without it; defer until a human actually
   needs to review R1 in-app. (Was my recommendation given their stated goal.)
2. **Month view + JSON download only** — least duplication, highest payoff. Shows a worked
   month and emits the portal JSON. Trigger the worker via console/manually. Skips the
   duplicative upload form and the 600-line exceptions twin.
3. **Full copy** — three LiveViews mirroring purchases. Complete, but ~900 largely-copied
   lines = the drift risk.
4. **Refactor to share the shell first** — extract the common upload/table/evidence shell
   so purchase and sales don't diverge, then build sales on it. Least long-term
   duplication, biggest lift, touches working purchase code (риск).

My read: **don't do (3).** Either (1) if they just want the engine, or (2) as a thin
useful slice, or (4) if they're committed to the full product surface and want it clean.
The `resolve`/exceptions half is where copy-paste hurts most — that's 600 lines that WILL
drift from the purchase version.

### Routes (when you build it)

`lib/nila_web/router.ex` around line 90, inside `live_session :require_verified` (the
authenticated + verified scope — **do not** put these outside it, they need
`current_scope`). Mirror the purchase routes:
```
live "/gstr1/upload", Gstr1UploadLive, :new
live "/gstr1/:client_id/:period", Gstr1MonthLive, :index
live "/gstr1/:client_id/:period/exceptions", Gstr1ExceptionsLive, :index
get  "/gstr1/:client_id/:period/evidence/:basename", Gstr1EvidenceController, :show  # or param the existing one
```
Tenancy comes from `current_scope.current_org` (server session), **never** a URL param —
that's how the evidence controller stays leak-proof across firms. Copy that discipline.

## Tips / gotchas for Fable

- **Follow the mirror.** Every sales module has a purchase twin. Before writing anything,
  `read` the purchase file and copy its shape — naming, tenancy, changeset style, test
  layout. The purchase side is battle-tested; don't invent new patterns.
- **`mix precommit` is the gate.** Format + compile-warnings-as-errors + full suite. It
  was green (326 tests) at handoff. Keep it green.
- **The Caltech scores are NOT bugs to "fix" blindly.** The eval showed R1 lower on
  Caltech (53–70%). When I investigated, the two suspects (HSN truncated to 4 digits;
  paise-vs-rupee rounding) are **not one-directional bugs** — Breeze *files* 4-digit HSN,
  Caltech files as-printed (6/8 digits); Caltech's rounding is *mixed*. There's no client-
  agnostic rule derivable from the invoice alone. **Do not bake in an `if caltech` patch —
  the eval's honesty rule voids the number if you do.** The reproduction test baselines
  lock current behavior so any change is visible. Improving Caltech is a *derivation
  iteration* task (with the fixtures as the harness), separate from step 5.
- **Don't re-duplicate the brain.** `scripts/gstr1_eval_lib.exs` now delegates to
  `Nila.Gst.Gstr1`. If you need derivation logic anywhere, call the module. Never copy
  logic back into a script or a LiveView.
- **GSTR-3B already exists** (`Nila.Gst.Gstr3b`, tested). It assembles the payment return
  from the R1 outward liability + the ITC position. If R1 work changes `derive/2`'s output
  shape, check `Gstr3b.liability_from_gstr1/1` still reads it. **Domain note the user
  cares about:** 3B is the *payment* return (maker-checker: junior assembles, **senior
  signs/files**) — if you touch 3B filing flow, the role gate (owner/admin capability
  check, like settings routes) is first-class, not an afterthought. And 3B ideally
  assembles from *reviewed* R1, not raw-derived — which is another reason step 5's review
  loop matters eventually.
- **The plan doc** `docs/.plans/2026-07-16-gstr1-productionize.md` has the full step-by-
  step spec and acceptance criteria. `docs/.plans/` is gitignored (local scratch).
- **Don't touch the two pre-existing `docs/` edits** (`README.md`, `prd.md`) sitting
  uncommitted in the tree — they're someone else's in-flight work, not part of this.

## Verify-it-yourself commands

```bash
mix test test/nila/gst/gstr1_test.exs          # engine + reproduction baselines
mix test test/nila/gst/gstr1_worker_test.exs   # end-to-end via Stub
mix precommit                                  # the full gate
git log --oneline -4                           # the four commits of this work
```
