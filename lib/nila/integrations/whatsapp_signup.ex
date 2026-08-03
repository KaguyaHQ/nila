defmodule Nila.Integrations.WhatsAppSignup do
  @moduledoc """
  Server-side Meta Embedded Signup client.

  Browser-returned asset IDs are correlation hints. The exchanged business
  token and Graph readback are authoritative before Nila persists a binding.
  """

  @phone_fields Enum.join(
                  ~w(id display_phone_number verified_name quality_rating code_verification_status status),
                  ","
                )
  @waba_fields "id,name,account_review_status,business_verification_status"

  def configured? do
    config = config()

    Enum.all?([:app_id, :app_secret, :config_id, :allowed_business_id], fn key ->
      present?(Keyword.get(config, key))
    end) and valid_graph_url?(Keyword.get(config, :graph_url))
  end

  def public_config do
    if configured?() do
      {:ok,
       %{
         app_id: config!(:app_id),
         config_id: config!(:config_id),
         graph_version: graph_version()
       }}
    else
      {:error, :whatsapp_embedded_signup_not_configured}
    end
  end

  def complete_signup(authorization_code, session)
      when is_binary(authorization_code) and is_map(session) do
    with :ok <- validate_session(session),
         {:ok, token} <- exchange_code(authorization_code),
         {:ok, business} <- fetch_business(token.access_token),
         :ok <- verify_business(session, business),
         {:ok, waba} <- fetch_waba(session["waba_id"], token.access_token),
         {:ok, phone} <- fetch_phone(session, token.access_token),
         :ok <- subscribe_waba(waba["id"], token.access_token),
         :ok <- verify_subscription(waba["id"], token.access_token),
         pin = registration_pin(),
         :ok <- register_phone(phone["id"], pin, token.access_token),
         {:ok, registered_phone} <- fetch_phone(session, token.access_token) do
      {:ok,
       %{
         access_token: token.access_token,
         token_type: token.token_type,
         expires_at: token.expires_at,
         two_step_pin: pin,
         business_id: business["client_business_id"],
         waba_id: waba["id"],
         waba_name: waba["name"],
         phone_number_id: phone["id"],
         display_phone_number: registered_phone["display_phone_number"],
         verified_name: registered_phone["verified_name"],
         phone_status: registered_phone["status"],
         code_verification_status: registered_phone["code_verification_status"],
         quality_rating: registered_phone["quality_rating"],
         account_review_status: waba["account_review_status"],
         business_verification_status: waba["business_verification_status"],
         webhook_subscribed: true,
         registered: true
       }}
    end
  end

  def verify_connection(%{
        credentials: %{"access_token" => access_token},
        settings: %{"business_id" => business_id, "waba_id" => waba_id},
        external_account_id: phone_number_id
      })
      when is_binary(access_token) and access_token != "" do
    session = %{
      "business_id" => business_id,
      "waba_id" => waba_id,
      "phone_number_id" => phone_number_id
    }

    with :ok <- validate_session(session),
         {:ok, business} <- fetch_business(access_token),
         :ok <- verify_business(session, business),
         {:ok, waba} <- fetch_waba(waba_id, access_token),
         {:ok, phone} <- fetch_phone(session, access_token),
         :ok <- verify_subscription(waba_id, access_token) do
      {:ok,
       %{
         "business_id" => business["client_business_id"],
         "waba_id" => waba["id"],
         "waba_name" => waba["name"],
         "display_phone_number" => phone["display_phone_number"],
         "verified_name" => phone["verified_name"],
         "phone_status" => phone["status"],
         "code_verification_status" => phone["code_verification_status"],
         "quality_rating" => phone["quality_rating"],
         "account_review_status" => waba["account_review_status"],
         "business_verification_status" => waba["business_verification_status"],
         "webhook_subscribed" => true,
         "readiness_checked_at" =>
           DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
       }}
    end
  end

  def verify_connection(_connection), do: {:error, :incomplete_whatsapp_connection}

  defp exchange_code(code) do
    params = [
      client_id: config!(:app_id),
      client_secret: config!(:app_secret),
      code: code
    ]

    case Req.get("#{graph_url()}/oauth/access_token", request_options(params: params)) do
      {:ok, %{status: status, body: %{"access_token" => access_token} = body}}
      when status in 200..299 ->
        {:ok,
         %{
           access_token: access_token,
           token_type: Map.get(body, "token_type", "bearer"),
           expires_at: expires_at(body["expires_in"])
         }}

      {:ok, %{status: status, body: body}} ->
        {:error, {:whatsapp_token_exchange_failed, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_business(access_token) do
    graph_get("/me", access_token, fields: "client_business_id")
  end

  defp fetch_waba(waba_id, access_token) do
    with {:ok, %{"id" => ^waba_id} = waba} <-
           graph_get("/#{waba_id}", access_token, fields: @waba_fields) do
      {:ok, waba}
    else
      {:ok, _waba} -> {:error, :whatsapp_waba_mismatch}
      error -> error
    end
  end

  defp fetch_phone(session, access_token) do
    phone_number_id = session["phone_number_id"]

    with {:ok, %{"data" => phones}} when is_list(phones) <-
           graph_get("/#{session["waba_id"]}/phone_numbers", access_token, fields: @phone_fields),
         %{} = phone <- Enum.find(phones, &(&1["id"] == phone_number_id)) do
      {:ok, phone}
    else
      nil -> {:error, :whatsapp_phone_number_mismatch}
      error -> error
    end
  end

  defp subscribe_waba(waba_id, access_token) do
    case Req.post(
           "#{graph_url()}/#{waba_id}/subscribed_apps",
           request_options(auth: {:bearer, access_token})
         ) do
      {:ok, %{status: status, body: %{"success" => true}}} when status in 200..299 ->
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, {:whatsapp_subscription_failed, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verify_subscription(waba_id, access_token) do
    with {:ok, %{"data" => apps}} when is_list(apps) <-
           graph_get("/#{waba_id}/subscribed_apps", access_token),
         true <- Enum.any?(apps, &subscribed_app?/1) do
      :ok
    else
      false -> {:error, :whatsapp_subscription_not_confirmed}
      error -> error
    end
  end

  defp register_phone(phone_number_id, pin, access_token) do
    body = %{"messaging_product" => "whatsapp", "pin" => pin}

    case Req.post(
           "#{graph_url()}/#{phone_number_id}/register",
           request_options(auth: {:bearer, access_token}, json: body)
         ) do
      {:ok, %{status: status, body: %{"success" => true}}} when status in 200..299 ->
        :ok

      {:ok, %{status: status, body: response}} ->
        {:error, {:whatsapp_registration_failed, status, response}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp graph_get(path, access_token, params \\ []) do
    case Req.get(
           "#{graph_url()}#{path}",
           request_options(auth: {:bearer, access_token}, params: params)
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:whatsapp_graph_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_business(session, %{"client_business_id" => business_id}) do
    allowed_business_id = config!(:allowed_business_id)

    if business_id == session["business_id"] and business_id == allowed_business_id do
      :ok
    else
      {:error, :whatsapp_business_mismatch}
    end
  end

  defp verify_business(_session, _business), do: {:error, :missing_client_business_id}

  defp validate_session(session) do
    if Enum.all?(~w(business_id waba_id phone_number_id), &valid_id?(session[&1])) do
      :ok
    else
      {:error, :invalid_whatsapp_signup_session}
    end
  end

  defp valid_id?(value) when is_binary(value),
    do: byte_size(value) <= 64 and value =~ ~r/^\d+$/

  defp valid_id?(_value), do: false

  defp subscribed_app?(%{"id" => id}), do: id == config!(:app_id)

  defp subscribed_app?(%{"whatsapp_business_api_data" => %{"id" => id}}),
    do: id == config!(:app_id)

  defp subscribed_app?(_app), do: false

  defp registration_pin do
    :crypto.strong_rand_bytes(4)
    |> :binary.decode_unsigned()
    |> rem(1_000_000)
    |> Integer.to_string()
    |> String.pad_leading(6, "0")
  end

  defp expires_at(expires_in) when is_integer(expires_in) and expires_in > 0 do
    DateTime.utc_now()
    |> DateTime.add(expires_in, :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp expires_at(_expires_in), do: nil

  defp graph_url, do: config!(:graph_url) |> String.trim_trailing("/")

  defp graph_version do
    graph_url()
    |> URI.parse()
    |> Map.fetch!(:path)
    |> String.trim_leading("/")
  end

  defp request_options(options) do
    config = config()

    config
    |> Keyword.get(:req_options, [])
    |> Keyword.put_new(:receive_timeout, Keyword.get(config, :receive_timeout, 30_000))
    |> Keyword.merge(options)
  end

  defp config, do: Application.get_env(:nila, __MODULE__, [])

  defp config!(key) do
    case Keyword.get(config(), key) do
      value when is_binary(value) and value != "" -> value
      _value -> raise "missing WhatsApp Embedded Signup config #{inspect(key)}"
    end
  end

  defp valid_graph_url?(url) when is_binary(url) do
    uri = URI.parse(url)

    uri.scheme == "https" and is_binary(uri.host) and is_binary(uri.path) and
      uri.path =~ ~r|^/v\d+\.\d+/?$|
  end

  defp valid_graph_url?(_url), do: false

  defp present?(value), do: is_binary(value) and value != ""
end
