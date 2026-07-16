ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Nila.Repo, :manual)

# Local storage writes real files under the OS temp dir during the suite; the DB
# sandbox rolls back rows but leaves these orphaned. Wipe the storage root once the
# suite finishes so rendered artifacts don't accumulate across runs.
ExUnit.after_suite(fn _results ->
  root = Keyword.fetch!(Application.fetch_env!(:nila, Nila.Storage), :root)
  File.rm_rf!(root)
end)
