defmodule NilaWeb.NoticesWorkspaceController do
  use NilaWeb, :controller
  alias Nila.{Clients, Notices}
  alias Nila.Accounts.Policy
  alias Nila.Gst.Portal
  alias Nila.Notices.Runs
  @salt "notices-workspace-otp-v1"

  plug :authorize

  def index(conn, _), do: json(conn, snapshot(conn.assigns.current_scope))

  def show(conn, %{"id" => id}) do
    with {:ok, id} <- id(id),
         {:ok, notice} <- Notices.fetch(conn.assigns.current_scope.current_org.id, id) do
      json(conn, %{notice: notice_data(notice)})
    else
      _ -> failure(conn, :not_found)
    end
  end

  def check_all(conn, _), do: result(conn, Runs.start(conn.assigns.current_scope))
  def retry(conn, _), do: result(conn, Runs.retry(conn.assigns.current_scope))

  def check(conn, params) do
    with_client(conn, params, fn scope, client ->
      case Notices.enqueue(scope, client.id) do
        {:error, :not_found} -> {:error, :connection_required}
        result -> result
      end
    end)
  end

  def otp(conn, params) do
    with_client(conn, params, fn scope, client ->
      with true <- Nila.Gstin.valid?(client.gstin),
           {:ok, challenge} <- Portal.request_otp(scope, client.id, params["username"]) do
        token =
          Phoenix.Token.encrypt(NilaWeb.Endpoint, @salt, %{
            user_id: scope.user.id,
            org_id: scope.current_org.id,
            client_id: client.id,
            challenge: challenge
          })

        {:challenge, %{challenge: token}}
      else
        false -> {:error, :invalid_account}
        error -> error
      end
    end)
  end

  def verify(conn, params) do
    with_client(conn, params, fn scope, client ->
      with {:ok, challenge} <- decrypt(params["challenge"], scope, client),
           {:ok, _} <- Portal.verify_otp(scope, challenge, params["otp"]) do
        # Connecting and checking are separate writes. A queue failure must not
        # make a successful OTP verification look like it failed.
        {:ok, :connected}
      end
    end)
  end

  defp decrypt(token, scope, client) when is_binary(token) do
    case Phoenix.Token.decrypt(NilaWeb.Endpoint, @salt, token, max_age: 900) do
      {:ok, %{user_id: user, org_id: org, client_id: id, challenge: challenge}}
      when user == scope.user.id and org == scope.current_org.id and id == client.id ->
        {:ok, challenge}

      _ ->
        {:error, :invalid_challenge}
    end
  end

  defp decrypt(_, _, _), do: {:error, :invalid_challenge}

  defp with_client(conn, params, fun) do
    scope = conn.assigns.current_scope

    with {:ok, id} <- id(params["client_id"]),
         {:ok, client} <- Clients.get_client(scope.current_org.id, id) do
      case fun.(scope, client) do
        {:challenge, body} -> json(conn, body)
        outcome -> result(conn, outcome)
      end
    else
      _ -> failure(conn, :not_found)
    end
  end

  defp result(conn, {:ok, _}), do: json(conn, snapshot(conn.assigns.current_scope))
  defp result(conn, {:error, reason}), do: failure(conn, reason)

  defp snapshot(scope) do
    checks = Notices.client_checks(scope.current_org.id)
    run = Runs.latest(scope.current_org.id)
    results = if run, do: Map.values(run.results), else: []
    failed_ids = if run, do: for({id, %{"state" => "failed"}} <- run.results, do: id), else: []

    %{
      user: %{name: scope.user.name, org: scope.current_org.name},
      permissions: %{
        check: Policy.can?(scope, :edit_records),
        connect: Policy.can?(scope, :manage_connectors)
      },
      checking: Runs.pending?(run) or Enum.any?(checks, &(&1.state == :checking)),
      clients:
        Enum.map(checks, fn row ->
          %{
            id: row.id,
            name: row.client.name,
            gstin: row.client.gstin,
            username:
              if(row.connection, do: row.connection.username, else: row.client.gst_username || ""),
            state: row.state,
            last_checked_at: row.last_checked_at,
            error: row.last_error,
            run_error: if(run, do: get_in(run.results, [to_string(row.id), "reason"]))
          }
        end),
      run:
        if(run,
          do: %{
            started_at: run.inserted_at,
            total: length(results),
            checked: Enum.count(results, &(&1["state"] == "checked")),
            pending: Enum.count(results, &(&1["state"] == "pending")),
            failed: length(failed_ids),
            retry_count:
              Enum.count(
                checks,
                &(to_string(&1.id) in failed_ids and &1.state in [:checked, :failed, :not_checked])
              )
          }
        ),
      notices:
        Enum.map(Notices.list(scope.current_org.id), fn notice ->
          notice
          |> notice_data()
          |> Map.put(:new, not is_nil(run) and notice.id in run.notice_ids)
        end)
    }
  end

  defp notice_data(notice) do
    period = get_in(notice.payload, ["detail", "taxPeriod"])

    %{
      id: notice.id,
      client_id: notice.client_id,
      client_name: notice.client.name,
      gstin: notice.gstin,
      reference: notice.reference,
      type:
        if(notice.notice_type == "REMINDER", do: "Reminder", else: notice.notice_type || "Notice"),
      issued_on: notice.issued_on,
      reply_due_on: notice.reply_due_on,
      period:
        case period do
          %{"fromMonth" => fm, "fromYear" => fy, "toMonth" => tm, "toYear" => ty} ->
            "#{fm} #{fy} – #{tm} #{ty}"

          _ ->
            nil
        end,
      documents:
        Notices.documents(notice)
        |> Enum.with_index()
        |> Enum.map(fn {doc, index} ->
          %{
            name: doc["docName"],
            type: doc["ct"],
            url: "/notices/#{notice.id}/documents/#{index}"
          }
        end)
    }
  end

  defp authorize(conn, _) do
    scope = conn.assigns[:current_scope]
    conn = put_resp_header(conn, "cache-control", "private, no-store")

    capability =
      case action_name(conn) do
        action when action in [:index, :show] -> :view
        action when action in [:otp, :verify] -> :manage_connectors
        _ -> :edit_records
      end

    cond do
      is_nil(scope) ->
        conn |> failure(:unauthenticated) |> halt()

      not scope.user.active or is_nil(scope.current_org) or is_nil(scope.user.confirmed_at) or
          not Policy.can?(scope, capability) ->
        conn |> failure(:forbidden) |> halt()

      true ->
        conn
    end
  end

  defp id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 and id <= 9_223_372_036_854_775_807 -> {:ok, id}
      _ -> {:error, :not_found}
    end
  end

  defp id(_), do: {:error, :not_found}

  defp failure(conn, reason) do
    {status, code, message} =
      case reason do
        :unauthenticated ->
          {401, "unauthenticated", "Sign in to view notices."}

        :forbidden ->
          {403, "forbidden", "Your role cannot perform this action."}

        :not_found ->
          {404, "not_found", "This notice or client is not available."}

        :session_expired ->
          {409, "connection_required", Notices.error_message(reason)}

        :connection_required ->
          {409, "connection_required", "Connect this client's GST account first."}

        :invalid_challenge ->
          {422, "invalid_challenge", "This verification request expired. Send a new OTP."}

        _ ->
          {422, "request_failed", Notices.error_message(reason)}
      end

    conn |> put_status(status) |> json(%{error: message, code: code})
  end
end
