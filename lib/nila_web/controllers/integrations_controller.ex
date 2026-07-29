defmodule NilaWeb.IntegrationsController do
  use NilaWeb, :controller

  require Logger

  alias Nila.Integrations
  alias Nila.Integrations.MicrosoftGrantWorker

  def connect(conn, %{"provider" => "gmail"} = params) do
    if org = conn.assigns.current_scope.current_org do
      connection_params = Map.get(params, "connection", %{})

      state =
        Phoenix.Token.sign(conn, "gmail_oauth", %{
          "org_id" => org.id,
          "label" => blank_to_nil(connection_params["label"] || params["label"])
        })

      conn
      |> redirect(external: gmail_adapter().authorize_url(state: state))
    else
      conn
      |> put_flash(:error, "Choose an organisation before connecting Gmail.")
      |> redirect(to: ~p"/today")
    end
  end

  # The tenant is committed before the admin ever reaches Microsoft, so the
  # value that comes back can be checked against something we chose. The
  # redirect only reports that a grant exists; it cannot say who may bind it.
  def connect(conn, %{"provider" => "microsoft"} = params) do
    connection_params = Map.get(params, "connection", %{})
    tenant_id = blank_to_nil(connection_params["tenant_id"] || params["tenant_id"])
    mailbox = blank_to_nil(connection_params["mailbox"] || params["mailbox"])

    with %{} = org <- conn.assigns.current_scope.current_org,
         true <- is_binary(tenant_id) and is_binary(mailbox) do
      state =
        Phoenix.Token.sign(conn, "microsoft_consent", %{
          "org_id" => org.id,
          "tenant_id" => tenant_id,
          "mailbox" => mailbox,
          "label" => blank_to_nil(connection_params["label"] || params["label"])
        })

      redirect(conn, external: microsoft_adapter().admin_consent_url(state))
    else
      nil ->
        conn
        |> put_flash(:error, "Choose an organisation before connecting Microsoft.")
        |> redirect(to: ~p"/today")

      false ->
        conn
        |> put_flash(:error, "Enter the Microsoft tenant ID and the mailbox to send from.")
        |> redirect(to: ~p"/settings/connectors")
    end
  end

  def connect(conn, _params) do
    conn
    |> put_flash(:error, "Unknown connector.")
    |> redirect(to: ~p"/settings/connectors")
  end

  def callback(conn, %{"provider" => "gmail", "code" => code, "state" => state}) do
    with {:ok, oauth_state} <- Phoenix.Token.verify(conn, "gmail_oauth", state, max_age: 600),
         {:ok, credentials} <- gmail_adapter().exchange_code(code),
         {:ok, external_account_id} <-
           gmail_adapter().profile_email(Map.fetch!(credentials, "access_token")),
         {:ok, _connection} <-
           Integrations.upsert_connection(%{
             org_id: oauth_state["org_id"],
             label: oauth_state["label"] || external_account_id,
             provider: "gmail",
             status: "active",
             last_status: "connected",
             last_status_at: DateTime.utc_now(),
             external_account_id: external_account_id,
             credentials: credentials,
             settings: %{"query" => "has:attachment"}
           }) do
      conn
      |> put_flash(:info, "Gmail connected.")
      |> redirect(to: ~p"/settings/connectors")
    else
      _error ->
        conn
        |> put_flash(:error, "Gmail connection failed.")
        |> redirect(to: ~p"/settings/connectors")
    end
  end

  def callback(conn, %{"provider" => "gmail"}) do
    conn
    |> put_flash(:error, "Gmail connection failed.")
    |> redirect(to: ~p"/settings/connectors")
  end

  def callback(
        conn,
        %{"provider" => "microsoft", "admin_consent" => "True", "state" => state} = params
      ) do
    with {:ok, consent} <- Phoenix.Token.verify(conn, "microsoft_consent", state, max_age: 900),
         :ok <- verify_tenant(consent, params["tenant"]),
         {:ok, connection} <- create_microsoft_connection(consent),
         {:ok, _job} <-
           %{connection_id: connection.id} |> MicrosoftGrantWorker.new() |> Oban.insert() do
      conn
      |> put_flash(:info, "Microsoft consent granted. Confirming the grant now.")
      |> redirect(to: ~p"/settings/connectors")
    else
      {:error, :tenant_mismatch} ->
        conn
        |> put_flash(:error, "That consent was granted in a different Microsoft tenant.")
        |> redirect(to: ~p"/settings/connectors")

      error ->
        Logger.warning("Microsoft consent could not be bound", reason: inspect(error))

        conn
        |> put_flash(:error, "Microsoft connection failed.")
        |> redirect(to: ~p"/settings/connectors")
    end
  end

  # Consent that arrives without usable state cannot be bound to a workspace,
  # which is a different situation from an admin declining.
  def callback(conn, %{"provider" => "microsoft", "admin_consent" => "True"}) do
    conn
    |> put_flash(:error, "Microsoft connection failed.")
    |> redirect(to: ~p"/settings/connectors")
  end

  def callback(conn, %{"provider" => "microsoft"}) do
    conn
    |> put_flash(:error, "Microsoft consent was not granted.")
    |> redirect(to: ~p"/settings/connectors")
  end

  def callback(conn, _params) do
    conn
    |> put_flash(:error, "Unknown connector.")
    |> redirect(to: ~p"/settings/connectors")
  end

  # Microsoft echoes the tenant that consented. A signed state proves who
  # started the flow but not which tenant they may claim, so the only binding
  # that counts is the one committed before the redirect.
  defp verify_tenant(%{"tenant_id" => tenant_id}, tenant_id) when is_binary(tenant_id), do: :ok
  defp verify_tenant(_consent, returned) when is_binary(returned), do: {:error, :tenant_mismatch}
  defp verify_tenant(_consent, _missing), do: {:error, :missing_tenant}

  defp create_microsoft_connection(consent) do
    Integrations.upsert_connection(%{
      org_id: consent["org_id"],
      provider: "microsoft",
      label: consent["label"] || consent["mailbox"],
      status: "active",
      last_status: "pending",
      last_status_at: DateTime.utc_now(),
      external_account_id: consent["mailbox"],
      tenant_id: consent["tenant_id"],
      credentials: %{}
    })
  end

  defp gmail_adapter do
    Application.get_env(:nila, :gmail_adapter, Nila.Integrations.Gmail)
  end

  defp microsoft_adapter do
    Application.get_env(:nila, :microsoft_adapter, Nila.Integrations.Microsoft)
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
