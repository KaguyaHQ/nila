# Phoenix and LiveView rules

For existing LiveView screens, preserve their components and tokens unless migration is requested. `assets/css/app.css`, `lib/nila_web/components/`, and `mix nila.style_guard` apply here.

- Wrap every LiveView template in `<Layouts.app flash={@flash} current_scope={@current_scope} ...>`. Put authenticated routes in the correct `live_session`.
- Call `<.flash_group>` only from `layouts.ex`.
- Use the shared `<.icon>` component, never Heroicons modules directly.
- Passing `class` to `<.input>` replaces all default classes; provide complete styling.

## Phoenix

- `scope` blocks already alias their routes — never add your own alias for a route; `scope "/admin", AppWeb.Admin` makes `live "/users", UserLive` resolve to `AppWeb.Admin.UserLive`. Watch for double prefixes.
- `Phoenix.View` is gone — don't use it.

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
