defmodule NilaWeb.IntegrationsController do
  use NilaWeb, :controller

  require Logger

  alias Nila.Integrations
  alias Nila.Integrations.MicrosoftGrantWorker

  # Setup is shelved; callbacks remain for consent already in flight.
  def connect(conn, _params), do: send_resp(conn, :gone, "Email connection setup is unavailable.")

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
      |> redirect(to: ~p"/app/settings/workspace")
    else
      _error ->
        conn
        |> put_flash(:error, "Gmail connection failed.")
        |> redirect(to: ~p"/app/settings/workspace")
    end
  end

  def callback(conn, %{"provider" => "gmail"}) do
    conn
    |> put_flash(:error, "Gmail connection failed.")
    |> redirect(to: ~p"/app/settings/workspace")
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
      |> redirect(to: ~p"/app/settings/workspace")
    else
      {:error, :tenant_mismatch} ->
        conn
        |> put_flash(:error, "That consent was granted in a different Microsoft tenant.")
        |> redirect(to: ~p"/app/settings/workspace")

      error ->
        Logger.warning("Microsoft consent could not be bound", reason: inspect(error))

        conn
        |> put_flash(:error, "Microsoft connection failed.")
        |> redirect(to: ~p"/app/settings/workspace")
    end
  end

  # Consent that arrives without usable state cannot be bound to a workspace,
  # which is a different situation from an admin declining.
  def callback(conn, %{"provider" => "microsoft", "admin_consent" => "True"}) do
    conn
    |> put_flash(:error, "Microsoft connection failed.")
    |> redirect(to: ~p"/app/settings/workspace")
  end

  def callback(conn, %{"provider" => "microsoft"}) do
    conn
    |> put_flash(:error, "Microsoft consent was not granted.")
    |> redirect(to: ~p"/app/settings/workspace")
  end

  def callback(conn, _params) do
    conn
    |> put_flash(:error, "Unknown connector.")
    |> redirect(to: ~p"/app/settings/workspace")
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
end
