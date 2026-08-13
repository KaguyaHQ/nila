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
  purchase_extractor: Nila.Gst.Extraction.Purchase.MistralOCR,
  sales_extractor: Nila.Gst.Extraction.Sales.MistralOCR,
  gmail_adapter: Nila.Integrations.Gmail,
  microsoft_adapter: Nila.Integrations.Microsoft,
  whatsapp_adapter: Nila.Integrations.WhatsApp,
  whatsapp_signup_adapter: Nila.Integrations.WhatsAppSignup,
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

config :nila, Nila.Gst.Extraction.Providers.Mistral,
  base_url: "https://api.mistral.ai",
  receive_timeout: 300_000

config :nila, Nila.Gst.Extraction.Providers.OpenAICompatibleChat,
  provider: "mistral",
  base_url: "https://api.mistral.ai/v1",
  model: "mistral-small-latest",
  response_format: :json_schema,
  receive_timeout: 300_000

config :nila, Nila.Gst.Extraction.OpenAICompatibleChatFinch, protocol: :http2

config :nila, Nila.Gst.Extraction.ProviderAdmission,
  tokens_per_minute: 100_000,
  requests_per_second: 1.67,
  max_concurrency: 100

config :hammer,
  backend:
    {Hammer.Backend.ETS,
     [
       expiry_ms: 60_000 * 60 * 2,
       cleanup_interval_ms: 60_000 * 10
     ]}

config :nila, Nila.Integrations.Microsoft,
  client_id: System.get_env("MICROSOFT_CLIENT_ID") || "dev-microsoft-client-id",
  client_secret: System.get_env("MICROSOFT_CLIENT_SECRET") || "dev-microsoft-client-secret",
  redirect_uri:
    System.get_env("MICROSOFT_REDIRECT_URI") ||
      "http://localhost:4000/integrations/microsoft/callback"

config :nila, Nila.Integrations.Gmail,
  client_id: System.get_env("GOOGLE_CLIENT_ID") || "dev-google-client-id",
  client_secret: System.get_env("GOOGLE_CLIENT_SECRET") || "dev-google-client-secret",
  redirect_uri:
    System.get_env("GMAIL_REDIRECT_URI") || "http://localhost:4000/integrations/gmail/callback"

config :nila, NilaWeb.Webhooks.WhatsAppController,
  app_secret: System.get_env("WHATSAPP_APP_SECRET") || "dev-whatsapp-app-secret",
  verify_token: System.get_env("WHATSAPP_VERIFY_TOKEN") || "dev-whatsapp-verify-token"

# Inbound email. Resend receives on a subdomain so its MX record cannot fight
# the firm's own mail; the reply address is signed with its own secret, which
# is what stops a stranger posting into a client's month.
config :nila, NilaWeb.Webhooks.ResendController,
  signing_secret: System.get_env("RESEND_WEBHOOK_SECRET")

config :nila, Nila.Integrations.Resend, api_key: System.get_env("RESEND_API_KEY")

config :nila, Nila.Gst.Intake.InboundAddress,
  domain: System.get_env("INBOUND_EMAIL_DOMAIN") || "inbound.nila.tax",
  secret: System.get_env("INBOUND_EMAIL_SECRET") || "dev-inbound-email-secret"

config :nila, Nila.Integrations.WhatsApp,
  graph_url: "https://graph.facebook.com/v26.0",
  receive_timeout: 30_000,
  max_media_bytes: 25_000_000

config :nila, Nila.Integrations.WhatsAppSignup,
  app_id: nil,
  app_secret: nil,
  config_id: nil,
  allowed_business_id: nil,
  graph_url: "https://graph.facebook.com/v26.0",
  receive_timeout: 30_000

config :nila, Oban,
  repo: Nila.Repo,
  queues: [
    documents: 5,
    whatsapp: 5,
    workflows: 10,
    reminders: 5,
    approvals: 5,
    chase: 5
  ],
  plugins: [
    Oban.Plugins.Pruner,
    # A node that dies mid-read leaves its job `executing` forever otherwise,
    # and a document read is the longest-running job here — minutes of provider
    # calls — so it is the one most likely to be interrupted by a deploy.
    Oban.Plugins.Lifeline,
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
