# Importing existing customer data

> **Status note (2026-06-06):** for the *first* live customer (Breezetech +
> Caltech) we onboard by **hand-entry into a catalog-driven form, not bulk
> import** — see [`../.plans/onboarding/README.md`](../.plans/onboarding/README.md)
> for the plan and rationale. The `mix nila.import_*` tasks below remain the
> bulk/later path; do not run them to seed Breezetech or Caltech.

Operational procedure (not a debug playbook) — kept here because it's a task you
run more than once: every new workspace, and again whenever a customer's sheet
changes. Three `mix nila.*` tasks seed a workspace from the data the customer
already has — their jobs sheet, their PO PDFs, and the Philips approver routing.

**Always pass the right `--org-id`.** There is no default; a wrong id writes into
another workspace. Find it first:

    mix run -e 'Nila.Repo.all(Nila.Orgs.Org) |> Enum.each(&IO.puts("#{&1.id}\t#{&1.name}"))'

For prod, run on the box against the running release. For anything risky, dry-run
locally against a dev DB first.

## Import historical quotes (the receivables master)

    mix nila.import_quotes <quotes.json> --org-id <ID> --entity-id <ID> [--actor-id <ID>]
    # -o is an alias for --org-id, -e for --entity-id

Imports the family's historical quotes (the extracted `quotes.json`, the spine of
the receivables master) via `Nila.Quotes.Import.import_json/2`, and prints
`imported` / `skipped` / `anomalies` counts. Copy-of tabs (duplicate quotes) are
skipped, and the entity's live quote counter is advanced past the highest
historical number so new quotes never collide. `--actor-id` attributes the import
to a user; omit it for a system import. Row mapping, skip rules, and the
upsert/audit logic live in `Nila.Quotes.Import` — read it there rather than
trusting this line if behaviour matters.

> Note: the quote is the lifecycle spine (see `decisions.md`, "Quote is the
> lifecycle spine"). The old `nila.import_work_orders` CSV path was removed with
> the `work_orders` table; PO, site, and status now live on the quote.

## Import a purchase-order PDF

    mix nila.import_po "<path/to/PO.pdf>" --org-id <ID> [--uploaded-by-id <ID>]

Stores a local PO PDF through `Nila.Storage`, creates the `Document` record, and
enqueues `PurchaseOrderExtractionWorker`. This is the CLI equivalent of the
in-app upload. The path may be URL-encoded (e.g. `PO%204532258231_AP.pdf`); it is
decoded internally, so quote it if it contains spaces or `%`.

The document lands as `needs_review` once extraction runs — but extraction stays
on the stub until `LLAMA_CLOUD_API_KEY` is set in prod (see `docs/TODO.md` §1),
so until then the artifact is placeholder data.

## Seed Philips SDC contacts + site routing

    mix nila.seed_contacts --org-id <ID>

Seeds the Philips SDC approver contacts and the site→region routing the approval
chase depends on. Run once per workspace before working acceptance items in `/today`.

## After importing

- Imported quotes surface on `/today` and `/receivables`.
- An imported PO surfaces in the review queue once its extraction job runs.
