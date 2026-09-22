defmodule NilaWeb.Gstr2bWorkspaceController do
  use NilaWeb, :controller
  alias Nila.Accounts.Policy
  alias Nila.Gst.Portal
  alias Nila.Gst.Portal.Gstr2b
  alias Nila.Gst.Purchase.PortalImport
  alias Nila.Gst.Intake.Dumps
  @salt "gstr2b-workspace-otp-v1"

  def show(conn, params),
    do: run(conn, params, fn scope, client, period -> {:ok, state(scope, client, period)} end)

  def fetch(conn, params) do
    run(conn, params, fn scope, client, period ->
      with {:ok, _} <- Gstr2b.enqueue(scope, client.id, period),
           do: {:accepted, state(scope, client, period)}
    end)
  end

  def import_statement(conn, params) do
    run(conn, params, fn scope, client, period ->
      with {:ok, _} <- PortalImport.import(scope, client.id, period),
           do: {:accepted, state(scope, client, period)}
    end)
  end

  def otp(conn, params) do
    run(conn, params, fn scope, client, period ->
      with true <- Nila.Gstin.valid?(client.gstin),
           {:ok, challenge} <- Portal.request_otp(scope, client.id, params["username"]) do
        token =
          Phoenix.Token.encrypt(NilaWeb.Endpoint, @salt, %{
            user_id: scope.user.id,
            org_id: scope.current_org.id,
            client_id: client.id,
            period: period,
            challenge: challenge
          })

        {:ok, %{challenge: token, username: challenge.account.username, expires_in: 900}}
      else
        false -> {:error, :invalid_gstin}
        error -> error
      end
    end)
  end

  def verify(conn, params) do
    run(conn, params, fn scope, client, period ->
      with true <- Policy.can?(scope, :manage_connectors),
           {:ok, challenge} <- decrypt(params["challenge"], scope, client, period),
           {:ok, _} <- Portal.verify_otp(scope, challenge, params["otp"]),
           {:ok, _} <- Gstr2b.enqueue(scope, client.id, period) do
        {:accepted, state(scope, client, period)}
      else
        false -> {:error, :forbidden}
        error -> error
      end
    end)
  end

  defp decrypt(token, scope, client, period) when is_binary(token) do
    case Phoenix.Token.decrypt(NilaWeb.Endpoint, @salt, token, max_age: 900) do
      {:ok, %{user_id: user, org_id: org, client_id: id, period: ^period, challenge: challenge}}
      when user == scope.user.id and org == scope.current_org.id and id == client.id ->
        {:ok, challenge}

      _ ->
        {:error, :invalid_challenge}
    end
  end

  defp decrypt(_, _, _, _), do: {:error, :invalid_challenge}

  defp run(conn, %{"client_id" => id, "period" => period}, action) do
    conn = put_resp_header(conn, "cache-control", "private, no-store")
    scope = conn.assigns[:current_scope]

    with :ok <- access(scope),
         {client_id, ""} when client_id > 0 and client_id <= 9_223_372_036_854_775_807 <-
           Integer.parse(id),
         {:ok, date} <- Gstr2b.month(period),
         true <- date.year >= 2017,
         {:ok, client} <- Nila.Clients.get_client(scope.current_org.id, client_id) do
      case action.(scope, client, period) do
        {:ok, body} -> json(conn, body)
        {:accepted, body} -> conn |> put_status(202) |> json(body)
        {:error, reason} -> failure(conn, reason)
      end
    else
      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "This client is not available.", code: "not_found"})

      {:error, reason} ->
        failure(conn, reason)

      _ ->
        failure(conn, :invalid_period)
    end
  end

  defp access(nil), do: {:error, :unauthenticated}
  defp access(%{user: %{confirmed_at: nil}}), do: {:error, :forbidden}
  defp access(%{current_org: nil}), do: {:error, :forbidden}
  defp access(scope), do: if(Policy.can?(scope, :view), do: :ok, else: {:error, :forbidden})

  defp state(scope, client, period) do
    statement = Gstr2b.saved(scope.current_org.id, client.id, period)

    imported =
      PortalImport.current_dump(statement, Dumps.list(scope.current_org.id, client.id, period))

    connection =
      case Portal.connection(scope.current_org.id, client.id) do
        {:ok, value} -> value
        _ -> nil
      end

    connection_state =
      cond do
        not Nila.Gstin.valid?(client.gstin) -> "missing_gstin"
        is_nil(connection) -> "not_connected"
        Portal.session_expired?(connection, DateTime.utc_now()) -> "expired"
        true -> "connected"
      end

    {:ok, availability} = Gstr2b.expected_availability(period)
    today = DateTime.utc_now() |> DateTime.add(19_800) |> DateTime.to_date()

    %{
      client: %{id: client.id, name: client.name, gstin: client.gstin},
      period: period,
      connection: %{
        state: connection_state,
        username: if(connection, do: connection.username, else: client.gst_username || "")
      },
      permissions: %{
        fetch: Policy.can?(scope, :edit_records),
        connect: Policy.can?(scope, :manage_connectors),
        export: Policy.can?(scope, :export)
      },
      statement:
        if(statement,
          do: %{
            id: statement.id,
            status: statement.status,
            fetched_at: statement.fetched_at,
            last_error: statement.last_error,
            failure_reason: statement.failure_reason,
            download_url:
              if(statement.fetched_at && Policy.can?(scope, :export),
                do: "/gst/2b/statements/#{statement.id}/download"
              )
          }
        ),
      fetching: Gstr2b.fetching?(statement),
      import: %{
        needed:
          not is_nil(statement) and not is_nil(statement.fetched_at) and
            (is_nil(imported) or imported.status == "failed"),
        status: imported && imported.status,
        error:
          if(imported && imported.status == "failed",
            do: "Could not prepare this statement for review. Try importing it again."
          )
      },
      availability_hint:
        if(Date.compare(today, availability) == :lt,
          do:
            "Normally available from #{Calendar.strftime(availability, "%d %B %Y")}. It may not be ready yet."
        )
    }
  end

  defp failure(conn, reason) do
    {status, code, message} =
      case reason do
        :unauthenticated ->
          {401, "unauthenticated", "Sign in to continue."}

        :forbidden ->
          {403, "forbidden", "Your role cannot perform this action."}

        :not_found ->
          {409, "connection_required", "Connect this client's GST account first."}

        :session_expired ->
          {409, "connection_required", Gstr2b.error_message(reason)}

        :invalid_challenge ->
          {422, "invalid_challenge",
           "This OTP request expired or is not valid. Request a new OTP."}

        :invalid_connection ->
          {422, "invalid_connection",
           "Check the GST username and six-digit OTP, or request a new OTP."}

        :invalid_gstin ->
          {422, "invalid_gstin", "Add a valid GSTIN to this client first."}

        message when is_binary(message) ->
          {422, "import_failed", message}

        _ ->
          {422, "request_failed", Gstr2b.error_message(reason)}
      end

    conn |> put_status(status) |> json(%{error: message, code: code})
  end
end
