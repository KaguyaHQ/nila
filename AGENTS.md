# Nila Agent Notes

Nila is a Phoenix monolith with a React + shadcn frontend in `frontend/`.
React owns all UI; Phoenix owns business truth. LiveView is removed.

## Product and scope

**The AI accountant.** The main GST workflow is sales bills → draft → exception
review → Excel workings for GSTR-1. Reduce manual preparation while preserving
source evidence, tax checks, and totals a senior can verify and retain.
See [the product objective and customer evidence](docs/prd.md#current-objective).

Purchases & ITC is also core GST work: GSTR-2B fetching, purchase review,
reconciliation, ITC decisions and purchase workings.

**Nila Business is also approved work:** small domestic service businesses create
sales documents and give their CA continuous access to structured sales data.
Its current scope includes customers, saved services, invoices, quotations,
credit notes, and downloadable PDFs. See `docs/business-invoicing.md` for the
implemented workflow. This does not authorize a full accounting or inventory suite.

Keep each task within the user's agreed scope. Banking, Tally and messaging
integrations are shelved; retained backend code is not a reason to rebuild their UI.
In GSTR-1 discussions, RCM means outward RCM (Table 4B).

## Complexity rule

**Unnecessary complexity is user harm.** Build the smallest faithful change.
If removing a label, state, abstraction or interaction preserves the user's
outcome and understanding, remove it. Do not improve adjacent areas unasked.
`docs/design/OPINIONS.md` remains guidance for product simplicity and necessity;
its product-scope statements yield to the approved scope above and user instructions.

## Architecture

- Phoenix owns calculations, validation and business transitions; Postgres is the source of truth.
- Oban handles background jobs. External processors return structured artifacts only.
- Humans resolve extraction exceptions before Phoenix commits business state.
- Contexts belong in `lib/nila/`; web code belongs in `lib/nila_web/`.
- Follow scoped instructions in `lib/AGENTS.md`, `lib/nila_web/AGENTS.md`,
  `test/AGENTS.md` and `frontend/AGENTS.md` when working in those areas.

## Commands and safety

```bash
# Local PostgreSQL is required on localhost:5432.
mix setup
mix phx.server
mix test
mix precommit
```

- Read `eval/README.md` before creating extraction evaluation runners or graders.
- Production access uses `./scripts/prod-console` (AWS Systems Manager). Production is read-only unless explicitly authorized.
- Pause before schema/data migrations, dependency/build/CI/precommit changes, mass rewrites, or deletion of material data unless already authorized in the session.
- Use Conventional Commits for commit messages.
- Push to `main` auto-deploys. Watch that run and check production health.
- Save temporary artifacts under root `outputs/`. Keep test artifacts in their configured locations.

## UI guidance

- Use shared components in `frontend/src/components/ui/`, tokens in `frontend/src/index.css`, and the user's agreed screen references. Inspect component APIs before use.
- Old `docs/design/` visual and implementation recipes are not authority for new React work. The product-principle exception for `OPINIONS.md` is explained above.
- Vite builds all frontend assets; Phoenix serves them. Public and error pages
  in `frontend/src/public/` render to HTML at build time and work without JavaScript.
- Never use the browser skill. Verify affected screens and actual interactions in the browser before calling UI work complete; builds and API tests alone do not establish visual quality.
