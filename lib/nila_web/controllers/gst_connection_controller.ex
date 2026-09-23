defmodule NilaWeb.GstConnectionController do
  use NilaWeb, :controller
  alias Nila.{Clients, Gst.Portal}
  alias Nila.Accounts.Policy
  @salt "client-gst-connection-v1"

  def show(conn, params), do: run(conn, params, :show)
  def otp(conn, params), do: run(conn, params, :otp)
  def verify(conn, params), do: run(conn, params, :verify)

  defp run(conn, params, action) do
    conn = put_resp_header(conn, "cache-control", "private, no-store")
    scope = conn.assigns[:current_scope]

    with :ok <- access(scope, action),
         {id, ""} when id > 0 and id <= 9_223_372_036_854_775_807 <-
           Integer.parse(params["client_id"]),
         {:ok, client} <- Clients.get_client(scope.current_org.id, id),
         {:ok, body} <- perform(action, scope, client, params) do
      json(conn, body)
    else
      {:error, reason} -> failure(conn, reason)
      _ -> failure(conn, :not_found)
    end
  end

  defp perform(:show, scope, client, _), do: {:ok, state(scope, client)}

  defp perform(:otp, scope, client, params) do
    with true <- Nila.Gstin.valid?(client.gstin),
         {:ok, challenge} <- Portal.request_otp(scope, client.id, params["username"]) do
      token =
        Phoenix.Token.encrypt(NilaWeb.Endpoint, @salt, %{
          user: scope.user.id,
          org: scope.current_org.id,
          client: client.id,
          challenge: challenge
        })

      {:ok, %{challenge: token, username: challenge.account.username, expires_in: 900}}
    else
      false -> {:error, :invalid_gstin}
      error -> error
    end
  end

  defp perform(:verify, scope, client, params) do
    with {:ok, challenge} <- decrypt(params["challenge"], scope, client),
         {:ok, _} <- Portal.verify_otp(scope, challenge, params["otp"]) do
      {:ok, state(scope, client)}
    end
  end

  defp decrypt(token, scope, client) when is_binary(token) do
    case Phoenix.Token.decrypt(NilaWeb.Endpoint, @salt, token, max_age: 900) do
      {:ok, %{user: user, org: org, client: id, challenge: challenge}}
      when user == scope.user.id and org == scope.current_org.id and id == client.id ->
        {:ok, challenge}

      _ ->
        {:error, :invalid_challenge}
    end
  end

  defp decrypt(_, _, _), do: {:error, :invalid_challenge}

  defp state(scope, client) do
    connection =
      case Portal.connection(scope.current_org.id, client.id) do
        {:ok, connection} -> connection
        _ -> nil
      end

    state =
      cond do
        not Nila.Gstin.valid?(client.gstin) -> "missing_gstin"
        is_nil(connection) -> "not_connected"
        Portal.session_expired?(connection, DateTime.utc_now()) -> "expired"
        true -> "connected"
      end

    %{
      state: state,
      username: if(connection, do: connection.username, else: client.gst_username || ""),
      can_connect: Policy.can?(scope, :manage_connectors)
    }
  end

  defp access(nil, _), do: {:error, :unauthenticated}
  defp access(%{user: %{confirmed_at: nil}}, _), do: {:error, :forbidden}
  defp access(%{current_org: nil}, _), do: {:error, :forbidden}

  defp access(scope, action) do
    permission = if action == :show, do: :view, else: :manage_connectors
    if Policy.can?(scope, permission), do: :ok, else: {:error, :forbidden}
  end

  defp failure(conn, reason) do
    {status, code, message} =
      case reason do
        :unauthenticated ->
          {401, "unauthenticated", "Sign in to continue."}

        :forbidden ->
          {403, "forbidden", "Your role cannot manage GST connections."}

        :not_found ->
          {404, "not_found", "This client is not available."}

        :invalid_gstin ->
          {422, "invalid_gstin", "Save a valid GSTIN for this client first."}

        :invalid_challenge ->
          {422, "invalid_challenge", "This OTP request expired. Request a new OTP."}

        :invalid_connection ->
          {422, "invalid_connection",
           "Check the GST username and six-digit OTP, or request a new OTP."}

        :not_configured ->
          {422, "not_configured",
           "GST access is not configured. Ask your administrator to set it up."}

        _ ->
          {422, "request_failed",
           "GST verification failed. Check the details and try again, or request a new OTP."}
      end

    conn |> put_status(status) |> json(%{error: message, code: code})
  end
end
