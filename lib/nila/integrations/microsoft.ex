defmodule Nila.Integrations.Microsoft do
  @behaviour Nila.Integrations.MailAdapter

  @moduledoc """
  Microsoft Graph adapter for outbound mail from a firm's own mailbox.

  App-only (`client_credentials`): the firm's admin consents once, tenant-wide,
  and Nila sends as a specific shared mailbox. There is no refresh token — the
  grant lives in the tenant, so an expired access token is re-minted rather
  than refreshed.

  The tenant grants send rights to every mailbox, so an Exchange
  `ApplicationAccessPolicy` scoping the app to one mailbox is a deployment
  requirement, not an optimisation.
  """

  alias Nila.Integrations

  @login_url "https://login.microsoftonline.com"
  @api_url "https://graph.microsoft.com/v1.0"
  @scope "https://graph.microsoft.com/.default"

  @impl true
  def ensure_token(connection) do
    if Integrations.token_fresh?(connection.credentials) do
      {:ok, connection}
    else
      with {:ok, tenant_id} <- fetch_tenant_id(connection),
           {:ok, minted} <- mint_token(tenant_id) do
        Integrations.update_credentials(connection, minted)
      end
    end
  end

  @impl true
  def send_message(connection, recipient, message) when is_binary(recipient) do
    with {:ok, access_token} <- Map.fetch(connection.credentials, "access_token") do
      mailbox = connection.external_account_id
      url = "#{@api_url}/users/#{URI.encode(mailbox)}/sendMail"

      body = %{
        "message" => graph_message(recipient, message, connection),
        "saveToSentItems" => true
      }

      options = [auth: {:bearer, access_token}, json: body] ++ req_options()

      case Req.post(url, options) do
        {:ok, %{status: status}} when status in 200..299 ->
          {:ok, %{mailbox: mailbox}}

        {:ok, %{status: status, body: response}} ->
          {:error, {:microsoft_send_error, status, response}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      :error -> {:error, :missing_access_token}
    end
  end

  def admin_consent_url(state) when is_binary(state) do
    params = [
      client_id: config!(:client_id),
      redirect_uri: config!(:redirect_uri),
      state: state
    ]

    "#{@login_url}/common/adminconsent?" <> URI.encode_query(params)
  end

  @doc """
  Confirms a tenant-wide grant is live by minting against it.

  The consent redirect only reports that a grant was recorded; it is not proof
  the caller may bind that tenant. Callers must separately verify the tenant
  against the signed state they issued.
  """
  def verify_grant(tenant_id) when is_binary(tenant_id), do: mint_token(tenant_id)

  defp mint_token(tenant_id) do
    form = %{
      "client_id" => config!(:client_id),
      "client_secret" => config!(:client_secret),
      "grant_type" => "client_credentials",
      "scope" => @scope
    }

    url = "#{@login_url}/#{tenant_id}/oauth2/v2.0/token"

    case Req.post(url, [form: form] ++ req_options()) do
      {:ok, %{status: status, body: %{"access_token" => _} = body}} when status in 200..299 ->
        minted_credentials(body)

      {:ok, %{status: status, body: body}} ->
        {:error, {:microsoft_token_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp graph_message(recipient, message, connection) do
    %{
      "subject" => Map.fetch!(message, :subject),
      "body" => %{"contentType" => "Text", "content" => Map.fetch!(message, :body)},
      "toRecipients" => [address(recipient)]
    }
    |> put_addresses("ccRecipients", setting(connection, "cc"))
    |> put_addresses("replyTo", reply_to(message, connection))
  end

  # A per-message reply address routes an answer back to one client and month,
  # so it wins over the connection-wide default when the caller sets one.
  defp reply_to(message, connection) do
    case Map.get(message, :reply_to) do
      value when is_binary(value) and value != "" -> [value]
      _absent -> List.wrap(setting_value(connection, "reply_to"))
    end
  end

  defp put_addresses(message, _key, []), do: message

  defp put_addresses(message, key, addresses),
    do: Map.put(message, key, Enum.map(addresses, &address/1))

  defp address(email), do: %{"emailAddress" => %{"address" => email}}

  defp setting(connection, key) do
    connection.settings
    |> Kernel.||(%{})
    |> Map.get(key, [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
  end

  defp setting_value(connection, key) do
    connection.settings |> Kernel.||(%{}) |> Map.get(key)
  end

  defp fetch_tenant_id(%{tenant_id: tenant_id}) when is_binary(tenant_id), do: {:ok, tenant_id}
  defp fetch_tenant_id(_connection), do: {:error, :missing_tenant_id}

  # App-only credentials are the whole token and nothing else: there is no
  # refresh token to carry forward, so each mint replaces the previous one.
  defp minted_credentials(%{"expires_in" => expires_in} = body) do
    expires_at =
      DateTime.utc_now()
      |> DateTime.add(expires_in, :second)
      |> DateTime.to_iso8601()

    {:ok, %{"access_token" => Map.fetch!(body, "access_token"), "expires_at" => expires_at}}
  end

  defp minted_credentials(_body), do: {:error, :missing_expires_in}

  defp req_options,
    do: Application.get_env(:nila, __MODULE__, []) |> Keyword.get(:req_options, [])

  defp config!(key) do
    value = Application.get_env(:nila, __MODULE__, []) |> Keyword.get(key)

    if value in [nil, ""] do
      raise "missing Microsoft config #{inspect(key)}"
    end

    value
  end
end
