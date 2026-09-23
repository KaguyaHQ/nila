# Backend tests

Read `../lib/AGENTS.md` for Elixir and Ecto rules when writing backend tests.

- Start processes with `start_supervised!/1` (guarantees cleanup).
- No `Process.sleep/1`/`Process.alive?/1`. To wait on exit: `Process.monitor/1` + `assert_receive {:DOWN, ^ref, :process, ^pid, :normal}`. To sync: `_ = :sys.get_state(pid)`.
- Debug failures: `mix test path:line`, `mix test --failed`, `mix help <task>` before using a task.

## Web tests

- Use Phoenix.ConnTest and API contract checks for controller behavior.
- React interactions are covered by Playwright in `frontend/tests`.
- There are no LiveView tests or product LiveViews.
