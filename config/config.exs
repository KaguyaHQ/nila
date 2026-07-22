# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :nila,
  ecto_repos: [Nila.Repo],
  generators: [timestamp_type: :utc_datetime_usec],
  bank_extractor: Nila.Banking.Extractor.Stub,
  purchase_extractor: Nila.Gst.Extraction.Purchase.MistralOCR,
  sales_extractor: Nila.Gst.Extraction.Sales.MistralOCR,
  gmail_adapter: Nila.Integrations.Gmail,
  whatsapp_adapter: Nila.Integrations.WhatsApp,
  whatsapp_chase_template: nil

config :nila, Nila.Repo, migration_timestamps: [type: :utc_datetime_usec]

config :nila, Nila.EncryptedMap, key: "dev-and-test-integration-credential-key"

config :nila, Nila.Assistant,
  http_client: Nila.Assistant.HTTPClient.Req,
  base_url: "https://api.stepfun.ai/v1",
  model: "step-3.7-flash",
  max_tokens: 4096,
  max_tool_iterations: 8,
  receive_timeout: 60_000

# LlamaExtract remains available only for explicit comparison benchmarks.
config :nila, Nila.Gst.Extraction.Purchase.LlamaExtract,
  base_url: "https://api.cloud.llamaindex.ai",
  tier: "agentic",
  version: "latest",
  receive_timeout: 60_000,
  poll_interval_ms: 3_000,
  max_polls: 200

# Sales-side LlamaExtract comparison adapter.
config :nila, Nila.Gst.Extraction.Sales.LlamaExtract,
  base_url: "https://api.cloud.llamaindex.ai",
  tier: "agentic",
  version: "latest",
  receive_timeout: 60_000,
  poll_interval_ms: 3_000,
  max_polls: 200

config :nila, Nila.Gst.Extraction.MistralOCR,
  base_url: "https://api.mistral.ai",
  receive_timeout: 300_000

config :hammer,
  backend:
    {Hammer.Backend.ETS,
     [
       expiry_ms: 60_000 * 60 * 2,
       cleanup_interval_ms: 60_000 * 10
     ]}

config :nila, Nila.Integrations.Gmail,
  client_id: System.get_env("GOOGLE_CLIENT_ID") || "dev-google-client-id",
  client_secret: System.get_env("GOOGLE_CLIENT_SECRET") || "dev-google-client-secret",
  redirect_uri:
    System.get_env("GMAIL_REDIRECT_URI") || "http://localhost:4000/integrations/gmail/callback"

config :nila, NilaWeb.Webhooks.WhatsAppController,
  app_secret: System.get_env("WHATSAPP_APP_SECRET") || "dev-whatsapp-app-secret",
  verify_token: System.get_env("WHATSAPP_VERIFY_TOKEN") || "dev-whatsapp-verify-token"

config :nila, Oban,
  repo: Nila.Repo,
  queues: [documents: 5, workflows: 10, reminders: 5, approvals: 5, chase: 5],
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Cron,
     crontab: [
       {"30 3 * * *", Nila.Gst.Chase.Scheduler}
     ]}
  ]

config :nila, Nila.Storage,
  adapter: Nila.Storage.Local,
  root: Path.expand("../priv/static/uploads", __DIR__),
  public_path: "/uploads"

# Configure the endpoint
config :nila, NilaWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: NilaWeb.ErrorHTML, json: NilaWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Nila.PubSub,
  live_view: [signing_salt: "ElOKzkeP"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :nila, Nila.Mailer, adapter: Swoosh.Adapters.Local

# Default sender for transactional email. Overridden in prod via MAIL_FROM /
# MAIL_FROM_NAME (see config/runtime.exs). `onboarding@resend.dev` is Resend's
# shared test sender — only delivers to your own Resend account email.
config :nila, :mail_from, {"Nila", "onboarding@resend.dev"}

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  nila: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.2.2",
  nila: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
