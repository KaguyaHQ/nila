# Nila Agent Notes

Nila is a Phoenix + LiveView monolith.

## Thesis

**The AI accountant.** Nila turns unstructured documents into GST drafts, flags uncertainty,
and asks humans only to resolve exceptions before Phoenix commits business truth. Build the
dump → draft → review loop, not data-entry forms. New features must expand artifact
coverage or materially improve that loop.

## Complexity Rule

**Unnecessary complexity is user harm.** Do not add a label, state, feature, abstraction,
interaction, explanation, or future-proofing unless the user's job cannot be completed or
understood without it. If removing something preserves the outcome, remove it. Implement
the smallest faithful scope; do not “improve” adjacent areas. Nila absorbs complexity—the
user must not learn Nila's internal model. See `docs/design/OPINIONS.md`.

## Product Boundary

- Phoenix owns business truth.
- Postgres is the source of truth.
- Oban handles background jobs and workflow execution.
- External processors return structured artifacts only.
- Humans approve exceptions before Phoenix commits business state.

## Commands

```bash
# dev.exs requires local PostgreSQL on localhost:5432.
mix setup
mix phx.server
mix test
mix precommit
```

## Production access

- Connect with `ssh nila-prod`. Production is read-only unless the user explicitly authorizes changes.

## Conventions

- Keep contexts under `lib/nila/`.
- Keep web code under `lib/nila_web/`.
- Use `Req` for HTTP calls when an integration is added.
- Use `Nila.Storage` rather than direct file writes outside storage adapters.
- Prefer boring Ecto schemas, explicit changesets, and audited transitions.
- Use the Conventional Commits 1.0.0 specification for commit messages.

## Transactional code

See `docs/decisions.md` (Transactional Code) for rationale.

- Default to `Repo.transact/1` around a flat `with` chain; do not nest transactions.
- Use `Ecto.Multi` only for runtime-composed steps or when callers need named-step failures.
- Use `Nila.Repo.fetch/2`, `fetch_one/1`, and `fetch_by/2` for composable reads.
- Inside transactions, use bang writes when failures are not meaningfully handled.

### Phoenix and LiveView

- Wrap every LiveView template in `<Layouts.app flash={@flash} current_scope={@current_scope} ...>`. Put authenticated routes in the correct `live_session`.
- Call `<.flash_group>` only from `layouts.ex`.
- Use the shared `<.icon>` component, never Heroicons modules directly.
- Passing `class` to `<.input>` replaces all default classes; provide complete styling.

### UI and design routing

- Never use the browser skill, even if it is listed as available in the session.
- Before changing product UI, read `docs/design/DESIGN.md` and `docs/design/OPINIONS.md`.
- For token, class, component, or mechanical UI work, also read `docs/design/FRONTEND.md`.
- For a new screen, workflow, or substantial restructuring, also read `docs/design/COMPOSITION.md` and `docs/design/TASTE.md`.
- For public/marketing pages, read `docs/design/MARKETING.md` and `docs/design/TASTE.md`.
- `assets/css/app.css` is authoritative for token values; `lib/nila_web/components/` owns shared recipes. Radix Themes 3.3 is the mechanical authority for generic controls, ported into HEEx with Nila's skin—never invent generic geometry or copy closed `nila-*` recipes into product markup. Token and recipe boundaries are enforced by `mix nila.style_guard`. Use the development-only `/dev/design-system` as the executable component reference.

### JS and CSS guidelines

- Preserve the Tailwind v4 `@import`/`@source` declarations in `assets/css/app.css`; never use `@apply`.
- Use only the `app.js` and `app.css` bundles. Import vendor dependencies into them; never add external script or stylesheet tags to layouts.

<!-- framework-rules-start -->
<!-- Hand-pruned digest of phoenix usage_rules. These are real model failure modes, not a
     language tutorial. Keep it tight; do not paste the full usage_rules dump back in. -->

## Elixir gotchas

- Lists have no index access (`list[i]` is invalid) — use `Enum.at/2`, pattern matching, or `List`.
- Block expressions (`if`/`case`/`cond`) don't mutate outer vars. Bind the whole expression; never reassign inside it:

      # INVALID — assignment is lost
      if connected?(socket) do socket = assign(socket, :val, val) end
      # VALID
      socket = if connected?(socket), do: assign(socket, :val, val), else: socket

- Structs don't implement Access — use `struct.field` / `Ecto.Changeset.get_field/2`, never `struct[:field]`.
- One module per file (nesting risks cyclic-dep/compile errors).
- Don't `String.to_atom/1` on user input (atom-table DoS).
- Predicate functions end in `?`, not `is_` (reserve `is_` for guards).
- Date/time: use stdlib `Time`/`Date`/`DateTime`/`Calendar`; the only allowed extra dep is `date_time_parser`.
- `DynamicSupervisor`/`Registry` need a `:name` in the child spec.
- Concurrent enumeration with back-pressure: `Task.async_stream/3`, usually `timeout: :infinity`.

## Tests

- Start processes with `start_supervised!/1` (guarantees cleanup).
- No `Process.sleep/1`/`Process.alive?/1`. To wait on exit: `Process.monitor/1` + `assert_receive {:DOWN, ^ref, :process, ^pid, :normal}`. To sync: `_ = :sys.get_state(pid)`.
- Debug failures: `mix test path:line`, `mix test --failed`, `mix help <task>` before using a task.

## Phoenix

- `scope` blocks already alias their routes — never add your own alias for a route; `scope "/admin", AppWeb.Admin` makes `live "/users", UserLive` resolve to `AppWeb.Admin.UserLive`. Watch for double prefixes.
- `Phoenix.View` is gone — don't use it.

## Ecto

- Preload associations a template will touch (else N+1 / KeyError).
- Schema string columns are `:string` even for `:text`.
- `validate_number/2` has no `:allow_nil` (validations skip nil changes already).
- Access changeset fields via `get_field/3`.
- Programmatic fields (`user_id`, …) must NOT be in `cast/3` — set them explicitly on the struct (security).
- Generate migrations only via `mix ecto.gen.migration name_with_underscores`.

## HEEx and forms

- Use the project's `<.input>` component for every form field; extend `lib/nila_web/components/input.ex` when necessary instead of hand-writing inputs.
- Build forms with `to_form/2` and `<.form for={@form}>`; access fields through `@form[:field]`. Give forms and interactive controls stable DOM IDs.
- Render collections with `<%= for ... %>`, not `Enum.each`.
- Use `<%!-- ... --%>` for template comments so they are not sent to the client.

## LiveView

- Use `<.link navigate={}/patch={}>` and `push_navigate`/`push_patch`; never deprecated `live_redirect`/`live_patch`.
- Prefer LiveViews over LiveComponents. Name LiveViews `...Live`.
- Use streams for collections, never `phx-update="append"` or `"prepend"`. Streams are not enumerable: track counts separately, refetch and reset to filter, and `stream_insert` rows when their rendered assigns change.
- Every `phx-hook` requires a unique DOM ID; add `phx-update="ignore"` when the hook owns its DOM.
- Never place raw `<script>` tags in HEEx. Use colocated hooks for inline behavior or register external hooks from `assets/js/`.

## LiveView tests

- Assert on elements, never raw HTML: `has_element?(view, "#id")`, `element/2`. Reference the DOM IDs you set in templates.
- Drive forms with `render_submit/2`/`render_change/2`. Test outcomes, not implementation; component output HTML may differ from your mental model — when a selector fails, dump with `LazyHTML.filter/2` to see the real structure.
<!-- framework-rules-end -->
