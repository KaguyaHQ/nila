# Elixir and data-layer rules

These rules apply to backend code.

## Conventions

- Use `Req` for HTTP integrations.
- Use `Nila.Storage` rather than direct file writes outside storage adapters.
- Prefer boring Ecto schemas, explicit changesets, and audited transitions.

## Transactional code

See `docs/decisions.md` (Transactional Code) for rationale.

- Default to `Repo.transact/1` around a flat `with` chain; do not nest transactions.
- Use `Ecto.Multi` only for runtime-composed steps or when callers need named-step failures.
- Use `Nila.Repo.fetch/2`, `fetch_one/1`, and `fetch_by/2` for composable reads.
- Inside transactions, use bang writes when failures are not meaningfully handled.

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

## Ecto

- Preload associations a template will touch (else N+1 / KeyError).
- Schema string columns are `:string` even for `:text`.
- `validate_number/2` has no `:allow_nil` (validations skip nil changes already).
- Access changeset fields via `get_field/3`.
- Programmatic fields (`user_id`, …) must NOT be in `cast/3` — set them explicitly on the struct (security).
