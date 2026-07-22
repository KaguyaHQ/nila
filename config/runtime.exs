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

config :phoenix, :filter_parameters, ["password", "api_key", "authorization", "bearer"]

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

# GST OCR provider selection is explicit. Credentials configure clients for the
# comparison benchmark, but never select a provider and never trigger fallback.
if config_env() in [:prod, :dev] do
  llama_key = env!("LLAMA_CLOUD_API_KEY", :string, nil)
  mistral_key = env!("MISTRAL_API_KEY", :string, nil)

  if llama_key do
    llama_config = [api_key: llama_key, project_id: env!("LLAMA_PROJECT_ID", :string, nil)]
    config :nila, Nila.Gst.PurchaseExtractor.LlamaExtract, llama_config
    config :nila, Nila.Gst.SalesExtractor.LlamaExtract, llama_config
  end

  if mistral_key do
    config :nila, Nila.Gst.MistralOCR, api_key: mistral_key
  end

  provider = env!("GST_OCR_PROVIDER", :string, if(config_env() == :dev, do: "mistral", else: nil))

  case provider do
    "llama" ->
      if is_nil(llama_key), do: raise("GST_OCR_PROVIDER=llama requires LLAMA_CLOUD_API_KEY")
      config :nila, :purchase_extractor, Nila.Gst.PurchaseExtractor.LlamaExtract
      config :nila, :sales_extractor, Nila.Gst.SalesExtractor.LlamaExtract

    "mistral" ->
      if is_nil(mistral_key), do: raise("GST_OCR_PROVIDER=mistral requires MISTRAL_API_KEY")
      config :nila, :purchase_extractor, Nila.Gst.PurchaseExtractor.MistralOCR
      config :nila, :sales_extractor, Nila.Gst.SalesExtractor.MistralOCR

    nil ->
      raise "GST_OCR_PROVIDER is required in production (llama or mistral)"

    other ->
      raise "unsupported GST_OCR_PROVIDER=#{inspect(other)}"
  end

  if base_url = env!("LLAMA_BASE_URL", :string, nil) do
    config :nila, Nila.Gst.PurchaseExtractor.LlamaExtract, base_url: base_url
    config :nila, Nila.Gst.SalesExtractor.LlamaExtract, base_url: base_url
  end

  if tier = env!("LLAMA_TIER", :string, nil) do
    config :nila, Nila.Gst.PurchaseExtractor.LlamaExtract, tier: tier
    config :nila, Nila.Gst.SalesExtractor.LlamaExtract, tier: tier
  end

  if version = env!("LLAMA_VERSION", :string, nil) do
    config :nila, Nila.Gst.PurchaseExtractor.LlamaExtract, version: version
    config :nila, Nila.Gst.SalesExtractor.LlamaExtract, version: version
  end

  if base_url = env!("MISTRAL_BASE_URL", :string, nil) do
    config :nila, Nila.Gst.MistralOCR, base_url: base_url
  end
end

# Transactional email (invites, etc.) via Resend, using Swoosh's built-in
# adapter over the Req API client. When `RESEND_API_KEY` is set we switch
# `Nila.Mailer` from the Local dev mailbox to Resend; absent, the Local adapter
# stays. NOTE: in prod with no key, mail is silently dropped (`local: false`),
# so invite emails won't deliver until this is set.
#
# `MAIL_FROM` / `MAIL_FROM_NAME` set the sender. The from-address domain must be
# verified in Resend (e.g. nilahq.com) or sends are rejected. Resend's shared
# `onboarding@resend.dev` sender only delivers to your own Resend account email,
# so it's fine for a first smoke test but NOT for inviting real teammates — set
# `MAIL_FROM=noreply@nilahq.com` once the domain is verified.
if config_env() in [:prod, :dev] do
  if template = env!("WHATSAPP_CHASE_TEMPLATE", :string, nil) do
    config :nila, whatsapp_chase_template: template
  end
end

if config_env() in [:prod, :dev] do
  if resend_key = env!("RESEND_API_KEY", :string, nil) do
    config :nila, Nila.Mailer,
      adapter: Swoosh.Adapters.Resend,
      api_key: resend_key

    if from_address = env!("MAIL_FROM", :string, nil) do
      from_name = env!("MAIL_FROM_NAME", :string, nil) || "Nila"
      config :nila, :mail_from, {from_name, from_address}
    end
  end
end

if config_env() == :prod do
  r2_endpoint = env!("R2_ENDPOINT", :string!)
  r2_uri = URI.parse(r2_endpoint)

  unless r2_uri.scheme == "https" and is_binary(r2_uri.host) and r2_uri.path in [nil, ""] do
    raise "environment variable R2_ENDPOINT must be an HTTPS account endpoint without a path"
  end

  config :ex_aws,
    http_client: ExAws.Request.Req,
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

  config :nila, NilaWeb.Webhooks.WhatsAppController,
    app_secret: System.get_env("WHATSAPP_APP_SECRET"),
    verify_token: System.get_env("WHATSAPP_VERIFY_TOKEN")

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
