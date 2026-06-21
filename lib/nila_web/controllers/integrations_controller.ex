defmodule NilaWeb.IntegrationsController do
  use NilaWeb, :controller

  alias Nila.Integrations

  def connect(conn, %{"provider" => "gmail"} = params) do
    if org = conn.assigns.current_scope.current_org do
      connection_params = Map.get(params, "connection", %{})

      state =
        Phoenix.Token.sign(conn, "gmail_oauth", %{
          "org_id" => org.id,
          "entity_id" => blank_to_nil(connection_params["entity_id"] || params["entity_id"]),
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

  def callback(conn, %{"provider" => "gmail", "code" => code, "state" => state}) do
    with {:ok, oauth_state} <- Phoenix.Token.verify(conn, "gmail_oauth", state, max_age: 600),
         {:ok, credentials} <- gmail_adapter().exchange_code(code),
         {:ok, external_account_id} <-
           gmail_adapter().profile_email(Map.fetch!(credentials, "access_token")),
         {:ok, _connection} <-
           Integrations.upsert_connection(%{
             org_id: oauth_state["org_id"],
             entity_id: oauth_state["entity_id"],
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

  defp gmail_adapter do
    Application.get_env(:nila, :gmail_adapter, Nila.Integrations.Gmail)
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
