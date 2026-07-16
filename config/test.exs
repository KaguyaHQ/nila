import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :nila, Nila.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "nila_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :nila, NilaWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Q3WHSfFKd8NKaphdMz1LwyXBZXiEDeKBUicGzMkYCA87f4M13f0q2+3wsTaMKJML",
  server: false

# In test we don't send emails
config :nila, Nila.Mailer, adapter: Swoosh.Adapters.Test

config :nila, Oban, testing: :manual, queues: false, plugins: false

config :nila, Nila.Storage,
  adapter: Nila.Storage.Local,
  root: Path.join(System.tmp_dir!(), "nila_test_uploads"),
  public_path: "/uploads"

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

config :nila, Nila.Assistant,
  http_client: Nila.Assistant.HTTPClient.Stub,
  api_key: "test-key",
  base_url: "https://api.stepfun.ai/v1",
  model: "step-3.7-flash",
  max_tokens: 4096,
  max_tool_iterations: 8
