import Config
import Dotenvy

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# Load `.env` for non-test environments. Real env vars take precedence over
# values in the file (kaguya pattern). Test config supplies its own values
# in config/test.exs and never touches dotenvy.
if config_env() != :test do
  _ = source([".env", System.get_env()])
end

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/nila start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :nila, NilaWeb.Endpoint, server: true
end

config :nila, NilaWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

config :phoenix,
       :filter_parameters,
       ~w(password api_key authorization authorization_code access_token client_secret bearer pin)

# OpenAI-compatible assistant. Provider-agnostic env names so swapping providers
# (StepFun, OpenAI, Groq, OpenRouter, …) is a secret change, not a code change.
# `ASSISTANT_BASE_URL` and `ASSISTANT_MODEL` are optional — when unset, the
# compile-time defaults from config/config.exs stand. `ASSISTANT_API_KEY` is
# required in prod; in dev nil → `/assistant` calls fail with :bad_request
# instead of crashing.
#
# `ASSISTANT_RECEIVE_TIMEOUT` (ms) tunes the upstream read timeout.
# `ASSISTANT_EXTRA_HEADERS` is a JSON object merged into every request's
# headers — this is what makes routing through an LLM gateway (Portkey,
# OpenRouter) a secret change, e.g.
# ASSISTANT_EXTRA_HEADERS='{"x-portkey-api-key":"…","x-portkey-provider":"openai"}'.
case config_env() do
  :prod -> config :nila, Nila.Assistant, api_key: env!("ASSISTANT_API_KEY", :string!)
  :dev -> config :nila, Nila.Assistant, api_key: env!("ASSISTANT_API_KEY", :string, nil)
  _ -> :ok
end

if config_env() in [:prod, :dev] do
  if base_url = System.get_env("ASSISTANT_BASE_URL") do
    config :nila, Nila.Assistant, base_url: base_url
  end

  if model = System.get_env("ASSISTANT_MODEL") do
    config :nila, Nila.Assistant, model: model
  end

  if timeout = System.get_env("ASSISTANT_RECEIVE_TIMEOUT") do
    config :nila, Nila.Assistant, receive_timeout: String.to_integer(timeout)
  end

  if extra_headers = System.get_env("ASSISTANT_EXTRA_HEADERS") do
    config :nila, Nila.Assistant, extra_headers: Jason.decode!(extra_headers)
  end
end

# Mistral is the sole GST extraction provider. Development remains optional so
# the app can boot without making OCR calls; production refuses to boot without
# the key rather than silently selecting or falling back to another provider.
if config_env() in [:prod, :dev] do
  mistral_key = env!("MISTRAL_API_KEY", :string, nil)

  if config_env() == :prod and is_nil(mistral_key) do
    raise "MISTRAL_API_KEY is required in production"
  end

  if mistral_key do
    config :nila, Nila.Gst.Extraction.Providers.Mistral, api_key: mistral_key
  end

  if base_url = env!("MISTRAL_BASE_URL", :string, nil) do
    config :nila, Nila.Gst.Extraction.Providers.Mistral, base_url: base_url
  end

  # The segmented pipeline's text calls — segmentation and per-invoice reading —
  # share the Mistral endpoint and can audition a cheaper text model independently
  # of the pinned OCR model.
  if model = env!("GST_TEXT_MODEL", :string, nil) do
    config :nila, Nila.Gst.Extraction.Providers.MistralChat, model: model
  end
end

# WhatsApp is a production intake boundary, so all webhook and outbound reply
# secrets are required together. Development remains opt-in.
case config_env() do
  :prod ->
    app_secret = env!("WHATSAPP_APP_SECRET", :string!)

    config :nila, whatsapp_chase_template: env!("WHATSAPP_CHASE_TEMPLATE", :string!)

    config :nila, NilaWeb.Webhooks.WhatsAppController,
      app_secret: app_secret,
      verify_token: env!("WHATSAPP_VERIFY_TOKEN", :string!)

  :dev ->
    if app_secret = env!("WHATSAPP_APP_SECRET", :string, nil) do
      config :nila, NilaWeb.Webhooks.WhatsAppController, app_secret: app_secret
    end

    if verify_token = env!("WHATSAPP_VERIFY_TOKEN", :string, nil) do
      config :nila, NilaWeb.Webhooks.WhatsAppController, verify_token: verify_token
    end

    if template = env!("WHATSAPP_CHASE_TEMPLATE", :string, nil) do
      config :nila, whatsapp_chase_template: template
    end

  _env ->
    :ok
end

if config_env() in [:prod, :dev] do
  signup_config =
    [
      app_id: env!("WHATSAPP_APP_ID", :string, nil),
      app_secret: env!("WHATSAPP_APP_SECRET", :string, nil),
      config_id: env!("WHATSAPP_EMBEDDED_SIGNUP_CONFIG_ID", :string, nil),
      allowed_business_id: env!("WHATSAPP_EMBEDDED_SIGNUP_ALLOWED_BUSINESS_ID", :string, nil)
    ]

  signup_requested =
    signup_config
    |> Keyword.take([:app_id, :config_id])
    |> Enum.any?(fn {_key, value} -> is_binary(value) and value != "" end)

  # ALLOWED_BUSINESS_ID pins onboarding to one Meta business. Leave it unset in
  # production and App Review so any customer business can authorise.
  if signup_requested do
    required = Keyword.take(signup_config, [:app_id, :app_secret, :config_id])

    case Enum.find(required, fn {_key, value} -> value in [nil, ""] end) do
      nil -> config :nila, Nila.Integrations.WhatsAppSignup, signup_config
      {key, _value} -> raise "WhatsApp Embedded Signup requires #{key}"
    end
  end
end

if graph_url = env!("WHATSAPP_GRAPH_URL", :string, nil) do
  graph_uri = URI.parse(graph_url)

  unless graph_uri.scheme == "https" and is_binary(graph_uri.host) and
           is_binary(graph_uri.path) and graph_uri.path =~ ~r|^/v\d+\.\d+/?$| do
    raise "WHATSAPP_GRAPH_URL must be an HTTPS Graph base URL ending in /vN.N"
  end

  config :nila, Nila.Integrations.WhatsApp, graph_url: graph_url
  config :nila, Nila.Integrations.WhatsAppSignup, graph_url: graph_url
end

# Transactional email (invites, etc.) via Resend, using Swoosh's built-in
# adapter over the Req API client. When `RESEND_API_KEY` is set we switch
# `Nila.Mailer` from the Local dev mailbox to Resend; absent, the Local adapter
# stays. NOTE: in prod with no key, mail is silently dropped (`local: false`),
# so invite emails won't deliver until this is set.
#
# `MAIL_FROM` / `MAIL_FROM_NAME` set the sender. The from-address domain must be
# verified in Resend or sends are rejected. `nila.tax` is verified, so prod uses
# `MAIL_FROM=noreply@nila.tax`. Resend's shared `onboarding@resend.dev` sender
# only delivers to your own Resend account email — fine for a smoke test, never
# for inviting real teammates.
if config_env() in [:prod, :dev] do
  if resend_key = env!("RESEND_API_KEY", :string, nil) do
    config :nila, Nila.Mailer,
      adapter: Swoosh.Adapters.Resend,
      api_key: resend_key

    if from_address = env!("MAIL_FROM", :string, nil) do
      from_name = env!("MAIL_FROM_NAME", :string, nil) || "Nila"
      config :nila, :mail_from, {from_name, from_address}
    end

    # Inbound uses the same account as sending, but the receiving domain is
    # verified separately — Resend tracks send and receive as distinct
    # capabilities, so a verified sending domain grants nothing here.
    config :nila, Nila.Integrations.Resend, api_key: resend_key
  end

  # Replies route by address, so both the domain that receives them and the
  # secret that signs them must be set for inbound to work at all. The webhook
  # secret is separate again: it is Resend proving the POST came from them.
  if inbound_domain = env!("INBOUND_EMAIL_DOMAIN", :string, nil) do
    config :nila, Nila.Gst.Intake.InboundAddress,
      domain: inbound_domain,
      secret: env!("INBOUND_EMAIL_SECRET", :string!)
  end

  if webhook_secret = env!("RESEND_WEBHOOK_SECRET", :string, nil) do
    config :nila, NilaWeb.Webhooks.ResendController, signing_secret: webhook_secret
  end
end

if config_env() in [:prod, :dev] do
  config :nila, Nila.EvalCorpus,
    endpoint: env!("R2_ENDPOINT", :string, nil),
    access_key_id: env!("R2_EVAL_ACCESS_KEY_ID", :string, nil),
    secret_access_key: env!("R2_EVAL_SECRET_ACCESS_KEY", :string, nil)
end

if config_env() == :prod do
  r2_endpoint = env!("R2_ENDPOINT", :string!)
  r2_uri = URI.parse(r2_endpoint)

  unless r2_uri.scheme == "https" and is_binary(r2_uri.host) and r2_uri.path in [nil, ""] do
    raise "environment variable R2_ENDPOINT must be an HTTPS account endpoint without a path"
  end

  config :ex_aws,
    http_client: Nila.Storage.ExAwsClient,
    access_key_id: env!("R2_ACCESS_KEY_ID", :string!),
    secret_access_key: env!("R2_SECRET_ACCESS_KEY", :string!),
    region: "auto",
    s3: [scheme: "https://", host: r2_uri.host, port: r2_uri.port || 443]

  config :nila, Nila.Storage, adapter: Nila.Storage.R2
  config :nila, Nila.Storage.R2, bucket: env!("R2_BUCKET", :string!)

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :nila, Nila.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :nila, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  integration_credential_key = System.get_env("INTEGRATION_CREDENTIAL_KEY") || secret_key_base

  config :nila, Nila.EncryptedMap, key: integration_credential_key

  config :nila, Nila.Integrations.Gmail,
    client_id: System.get_env("GOOGLE_CLIENT_ID"),
    client_secret: System.get_env("GOOGLE_CLIENT_SECRET"),
    redirect_uri: System.get_env("GMAIL_REDIRECT_URI")

  config :nila, Nila.Integrations.Microsoft,
    client_id: System.get_env("MICROSOFT_CLIENT_ID"),
    client_secret: System.get_env("MICROSOFT_CLIENT_SECRET"),
    redirect_uri: System.get_env("MICROSOFT_REDIRECT_URI")

  config :nila, NilaWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    # Behind Caddy/Cloudflare the browser's Origin is the public host. Reject
    # LiveView socket connections from any other origin.
    check_origin: ["https://#{host}"],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :nila, NilaWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :nila, NilaWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # The mailer (Resend via Swoosh) is configured above, gated on `RESEND_API_KEY`.
  # `config :swoosh, :api_client, Swoosh.ApiClient.Req` lives in config/prod.exs.
end
