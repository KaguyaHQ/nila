# `archived` tests read the gitignored eval artifacts under tmp/eval/. Excluded
# by default so a cold checkout reports "excluded" rather than a silent skip
# that reads as a pass.
ExUnit.start(exclude: [r2_integration: true, archived: true])
Ecto.Adapters.SQL.Sandbox.mode(Nila.Repo, :manual)

# Local storage writes real files under the OS temp dir during the suite; the DB
# sandbox rolls back rows but leaves these orphaned. Wipe the storage root once the
# suite finishes so rendered artifacts don't accumulate across runs.
ExUnit.after_suite(fn _results ->
  root = Keyword.fetch!(Application.fetch_env!(:nila, Nila.Storage), :root)
  File.rm_rf!(root)
end)
