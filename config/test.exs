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

config :nila,
  whatsapp_signup_adapter: Nila.Integrations.WhatsAppSignupStub,
  whatsapp_chase_template: "nila_document_chase",
  purchase_extractor: Nila.Gst.Extraction.Purchase.Stub,
  sales_extractor: Nila.Gst.Extraction.Sales.Stub

config :nila, Nila.Integrations.WhatsApp,
  graph_url: "https://graph.facebook.com/v26.0/",
  max_media_bytes: 16,
  req_options: [plug: {Req.Test, Nila.Integrations.WhatsApp}]

config :nila, Nila.Integrations.WhatsAppSignup,
  app_id: "123456789",
  app_secret: "test-whatsapp-app-secret",
  config_id: "987654321",
  graph_url: "https://graph.facebook.com/v26.0/",
  req_options: [plug: {Req.Test, Nila.Integrations.WhatsAppSignup}]

config :nila, Nila.Integrations.Gmail, req_options: [plug: {Req.Test, Nila.Integrations.Gmail}]

config :nila, Nila.Integrations.Microsoft,
  req_options: [plug: {Req.Test, Nila.Integrations.Microsoft}]

config :nila, Nila.Storage,
  adapter: Nila.Storage.Local,
  root: Path.join(System.tmp_dir!(), "nila_test_uploads"),
  public_path: "/uploads"

config :nila, Nila.Storage.R2, bucket: "test-bucket"

config :ex_aws,
  http_client: Nila.Storage.ExAwsClient,
  access_key_id: "test-access-key",
  secret_access_key: "test-secret-key",
  region: "auto",
  s3: [scheme: "https://", host: "r2.example.test"]

config :ex_aws, :req_opts, plug: {Req.Test, Nila.Storage.R2Test}

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

config :nila, Nila.Gst.Extraction.Providers.Mistral,
  api_key: "test-mistral-key",
  req_options: [plug: {Req.Test, Nila.Gst.Extraction.Providers.Mistral}]

# The segmented pipeline's text calls get their own stub, so an OCR expectation
# and a chat expectation can never satisfy each other.
config :nila, Nila.Gst.Extraction.Providers.OpenAICompatibleChat,
  provider: "mistral",
  base_url: "https://api.mistral.ai/v1",
  api_key: "test-mistral-key",
  model: "mistral-small-latest",
  response_format: :json_schema,
  req_options: [plug: {Req.Test, Nila.Gst.Extraction.Providers.OpenAICompatibleChat}]

# Req.Test replaces the adapter, so an eager real H2 connection would only add
# DNS/reconnect noise to the test application.
config :nila, Nila.Gst.Extraction.OpenAICompatibleChatFinch,
  start: false,
  protocol: :http2

config :nila, Nila.Assistant,
  http_client: Nila.Assistant.HTTPClient.Stub,
  api_key: "test-key",
  base_url: "https://api.stepfun.ai/v1",
  model: "step-3.7-flash",
  max_tokens: 4096,
  max_tool_iterations: 8

# bcrypt's cost is 2^log_rounds, so the production default of 12 makes every
# fixture user cost ~250ms — the suite was spending most of its wall clock
# proving it resists offline cracking, against attackers who do not exist here.
# `phx.gen.auth` writes this line for you; this repo's auth was copied in from
# the nila-ops substrate, so it never arrived. Test env only.
config :bcrypt_elixir, log_rounds: 1
