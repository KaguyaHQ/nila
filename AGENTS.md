# Nila Agent Notes

Nila is a Phoenix + LiveView monolith. Nila is the AI accountant.

## Thesis

**The AI accountant.** Nila does the junior accountant's job, starting with GST: the user
dumps an unstructured mess (a PDF, a photo, a paste, a forwarded statement), Nila
extracts → classifies → drafts the structured artifact (invoice record, return line),
flags the uncertain lines, and the human only touches the exceptions before Phoenix
commits business truth. We are not building data-entry forms; we are building the
dump → draft → review loop. When you add a feature, ask "does this make the loop work on
a new artifact type, or is it just a form?" Build the loop.

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

## Conventions

- Keep contexts under `lib/nila/`.
- Keep web code under `lib/nila_web/`.
- Use `Req` for HTTP calls when an integration is added.
- Use `Nila.Storage` rather than direct file writes outside storage adapters.
- Prefer boring Ecto schemas, explicit changesets, and audited transitions.
- Use the Conventional Commits 1.0.0 specification for commit messages.

## Transactional Code

Rationale lives in `docs/decisions.md` (Transactional Code).

- Default to `Repo.transact(fn -> ... end)` wrapping a `with` chain. The callback returns `{:ok, value} | {:error, reason}`; the wrapper commits or rolls back accordingly.
- Reach for `Ecto.Multi` only when you need one of: (a) dynamic step composition built at runtime, (b) the `{:error, step_name, value, changes_so_far}` failure tuple for callers, or (c) genuinely declarative chains that benefit from named results across many callers. Audit-log + entity-update pairs do not qualify.
- Inside a `transact` callback, use `Repo.insert!` / `update!` for writes that should never fail under normal operation (audit logs, event records, derived rows). Reserve `{:ok, _}`-returning calls for writes whose error path the caller actually handles.
- Use `Nila.Repo.fetch/2`, `fetch_one/1`, and `fetch_by/2` to get `{:ok, row} | {:error, :not_found}` so reads compose into `with` chains without per-call `nil` guards. Do not introduce raw `Repo.get(...) |> case do nil -> ... end` glue.
- Do not use tagged `with` patterns (`with {:step, {:ok, x}} <- {:step, ...}`). If you need step-specific error handling, push that step into a private function that returns a flat `{:ok, _} | {:error, _}`.
- Avoid nesting `Repo.transaction` / `Repo.transact` calls. Once a Postgres transaction aborts, the connection is poisoned until rollback; savepoint semantics have historically had sharp edges and are not worth introducing without a concrete need.

### Phoenix v1.8 guidelines

- **Always** begin your LiveView templates with `<Layouts.app flash={@flash} ...>` which wraps all inner content (`Layouts` is already aliased)
- Anytime you run into errors with no `current_scope` assign:
  - You failed to follow the Authenticated Routes guidelines, or you failed to pass `current_scope` to `<Layouts.app>`
  - **Always** fix the `current_scope` error by moving your routes to the proper `live_session` and ensure you pass `current_scope` as needed
- Phoenix v1.8 moved the `<.flash_group>` component to the `Layouts` module. You are **forbidden** from calling `<.flash_group>` outside of the `layouts.ex` module
- Out of the box, `core_components.ex` imports an `<.icon name="hero-x-mark" class="w-5 h-5"/>` component for hero icons. **Always** use the `<.icon>` component for icons, **never** use `Heroicons` modules or similar
- If you override the default input classes (`<.input class="myclass px-2 py-1 rounded-lg">)`) class with your own values, no default classes are inherited, so your
custom classes must fully style the input

### JS and CSS guidelines

- Tailwindcss v4 **no longer needs a tailwind.config.js** and uses a new import syntax in `app.css`:

      @import "tailwindcss" source(none);
      @source "../css";
      @source "../js";
      @source "../../lib/nila_web";

- **Always use and maintain this import syntax** in the app.css file for projects generated with `phx.new`
- **Never** use `@apply` when writing raw css
- This project uses **daisyUI v5 + the bespoke "moonlight" tokens** (see `docs/design/DESIGN.md`). Build from the shared components in `core_components.ex`; never hard-code colors or hex. (Overrides the generic phx.new "write your own, no daisyUI" default.)
- Out of the box **only the app.js and app.css bundles are supported**
  - You cannot reference an external vendor'd script `src` or link `href` in the layouts
  - You must import the vendor deps into app.js and app.css to use them

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

## HEEx / forms — read before editing `.heex`

- **YOU MUST use the project's `<.input>` component for every form field** (it carries label + `<.error>` + design tokens). If a field needs something `<.input>` can't do, **extend the component** (add a clause in `core_components.ex`) — do NOT hand-roll a raw `<input>`, or you silently lose error rendering and design-system consistency.
- Forms: build with `to_form/2` + `<.form for={@form} id="...">`, drive fields via `@form[:field]`. Never `<.form for={@changeset}>`, never `form_for`/`let={f}`. Always give forms/buttons unique DOM IDs (tests rely on them).
- Interpolation: `{...}` works in attrs and bodies; `<%= ... %>` only in bodies. Block constructs (`if`/`cond`/`case`/`for`) in a body use `<%= ... %>`. Never interpolate into an attribute with `<%= %>` (`id="<%= @x %>"` is a syntax error — use `id={@x}`).
- No `else if`/`elsif` — use `cond`/`case`. No `Enum.each` for content — use `<%= for x <- @col do %>`. Comments are `<%!-- … --%>`.
- Multi-value classes use list syntax: `class={["base", @flag && "x", if(@c, do: "a", else: "b")]}` (wrap inline `if` in parens).
- Literal `{`/`}` in a `<pre>`/`<code>` needs `phx-no-curly-interpolation` on the parent.

## LiveView

- Navigation: `<.link navigate={} />`/`patch={}` and `push_navigate`/`push_patch`. Never `live_redirect`/`live_patch`.
- Avoid LiveComponents unless you have a specific need. Name LiveViews `…Live`.
- **Collections → streams**, not list assigns (memory). Parent needs `id` + `phx-update="stream"`; iterate `@streams.name` using the row id as DOM id. Streams aren't enumerable: to filter, refetch and re-`stream(..., reset: true)`. No built-in count/empty — track count in a separate assign; empty state via `class="hidden only:block"`. When an assign changes content inside a streamed row, `stream_insert` that row too. Never `phx-update="append"`/`"prepend"`.
- JS hooks: every `phx-hook` needs a unique DOM id; if the hook owns its DOM, add `phx-update="ignore"`.
- **Never put a raw `<script>` in HEEx.** For inline scripts use a colocated hook (name MUST start with `.`); it's auto-bundled into app.js:

      <input id="user-phone" phx-hook=".PhoneNumber" />
      <script :type={Phoenix.LiveView.ColocatedHook} name=".PhoneNumber">
        export default { mounted() { /* this.el … */ } }
      </script>

  External hooks live in `assets/js/` and are passed to the `LiveSocket` `hooks:` map.
- Client/server events: `push_event(socket, "evt", %{})` (rebind socket) → `this.handleEvent("evt", …)`; `this.pushEvent("evt", payload, reply => …)` → server replies with `{:reply, %{}, socket}`.

## LiveView tests

- Assert on elements, never raw HTML: `has_element?(view, "#id")`, `element/2`. Reference the DOM IDs you set in templates.
- Drive forms with `render_submit/2`/`render_change/2`. Test outcomes, not implementation; component output HTML may differ from your mental model — when a selector fails, dump with `LazyHTML.filter/2` to see the real structure.
<!-- framework-rules-end -->
