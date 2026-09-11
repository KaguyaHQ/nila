# Decisions

Current structural choices and why they exist. See [the architecture](architecture.md)
for the code map and [AGENTS.md](../AGENTS.md) for implementation conventions.

## One Phoenix application

The UI, jobs, review, and business state live together because they participate in
one document-to-working flow. A monolith keeps changes local and avoids coordinating
separate services for each step.

## Postgres owns business state

Postgres stores clients, dumps, extraction attempts, invoice corrections, month
workings, review decisions, and filing records. External processors return artifacts;
Phoenix decides how to validate and persist them. Oban executes background work,
but its job state does not replace those business records.

## Source facts and human decisions stay distinct

Original extraction remains available. Source corrections and month review decisions
are recorded separately and applied when building the effective sales working.
That preserves what the bill said, what Nila read, and what the accountant changed.
See [the sales code guide](../lib/nila/gst/sales/README.md) for the ownership boundaries.

## Storage behind an adapter

`Nila.Storage` keeps upload and evidence code independent of storage providers.
Development and tests use local disk; `config/runtime.exs` selects `Nila.Storage.R2`
for production. The R2 adapter uses ExAws through `Nila.Storage.ExAwsClient`.

`url/2` provides signed downloads and `presign_put/2` supports direct browser uploads,
with a maximum lifetime of five minutes. Controllers can also fetch evidence through
`get/2` after checking access. Intake owns source keys and their relationship to
saved invoices; storage owns bytes, not accounting meaning.

## Transactional Code

Default to `Repo.transact/1` around a flat `with` chain. For the usual fixed sequence
of reads and writes, this keeps the business steps and failures visible without a
second vocabulary of named steps and intermediate context maps.

- Use `Repo.fetch/2`, `fetch_one/1`, and `fetch_by/2` for reads that compose into `with`.
- Return `{:ok, value}` to commit and `{:error, reason}` to roll back.
- Use bang writes when failure cannot be meaningfully handled by the caller.
- Use `Ecto.Multi` when steps are composed at runtime or named-step failures matter.
- Do not nest transactions. A function named `*_in_transaction` runs inside its
  caller's transaction; moving it to another module does not change that ownership.

## Earlier decisions

[The historical record](archive/decisions-history.md) preserves earlier designs,
retired modules, and the longer transaction rationale. It is not a roadmap or a
current inventory of implemented features.
