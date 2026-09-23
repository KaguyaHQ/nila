# Backend tests

Read `../lib/AGENTS.md` for Elixir and Ecto rules when writing backend tests.

- Start processes with `start_supervised!/1` (guarantees cleanup).
- No `Process.sleep/1`/`Process.alive?/1`. To wait on exit: `Process.monitor/1` + `assert_receive {:DOWN, ^ref, :process, ^pid, :normal}`. To sync: `_ = :sys.get_state(pid)`.
- Debug failures: `mix test path:line`, `mix test --failed`, `mix help <task>` before using a task.

## LiveView tests

- Assert on elements, never raw HTML: `has_element?(view, "#id")`, `element/2`. Reference the DOM IDs you set in templates.
- Drive forms with `render_submit/2`/`render_change/2`. Test outcomes, not implementation; component output HTML may differ from your mental model — when a selector fails, dump with `LazyHTML.filter/2` to see the real structure.
