if Mix.env() == :dev do
  Nila.Development.setup()
  IO.puts("Local workspaces ready: Firm workspace and Business workspace at /users/log_in.")
end
