defmodule Nila.Gst.Portal do
  @moduledoc "Shared GST access: client authentication and taxpayer lookups through Whitebooks."
  import Ecto.Query
  alias Nila.{Clients, Repo}
  alias Nila.Accounts.Policy
  alias Nila.Integrations.Whitebooks
  alias Nila.Gst.Portal.{Challenge, Connection}

  def connections(org_id) do
    Repo.all(
      from c in Connection,
        join: client in assoc(c, :client),
        where: client.org_id == ^org_id and client.gstin == c.gstin
    )
    |> Map.new(&{&1.client_id, &1})
  end

  def request_otp(scope, client_id, username) do
    with :ok <- authorize(scope, :manage_connectors),
         {:ok, client} <- Clients.get_client(scope.current_org.id, client_id),
         true <-
           is_binary(username) and String.trim(username) != "" and String.length(username) <= 100,
         {:ok, ip} <- ip_address(),
         account = %{gstin: client.gstin, username: String.trim(username), ip_address: ip},
         {:ok, %{"txn" => txn}} when is_binary(txn) and txn != "" <-
           Whitebooks.request_otp(account) do
      {:ok,
       %Challenge{
         account: Map.put(account, :txn, txn),
         client_id: client.id,
         requested_at: DateTime.utc_now(),
         org_id: scope.current_org.id
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_connection}
    end
  end

  def verify_otp(scope, challenge, otp) do
    with :ok <- authorize(scope, :manage_connectors),
         true <-
           is_struct(challenge, Challenge) and challenge.org_id == scope.current_org.id and
             is_binary(otp) and Regex.match?(~r/^\d{6}$/, otp),
         true <- DateTime.diff(DateTime.utc_now(), challenge.requested_at) in 0..899,
         {:ok, client} <- Clients.get_client(scope.current_org.id, challenge.client_id),
         true <- client.gstin == challenge.account.gstin,
         {:ok, _} <- Whitebooks.authenticate(challenge.account, otp) do
      account = challenge.account

      %Connection{client_id: client.id}
      |> Ecto.Changeset.change(%{
        gstin: client.gstin,
        username: account.username,
        credentials: %{"txn" => account.txn, "ip_address" => account.ip_address},
        authorized_at: DateTime.utc_now()
      })
      |> Repo.insert(
        on_conflict:
          {:replace,
           [
             :gstin,
             :username,
             :credentials,
             :authorized_at,
             :updated_at
           ]},
        conflict_target: [:client_id],
        returning: true,
        log: false
      )
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_connection}
    end
  end

  def connection(org_id, client_id) do
    Repo.fetch_one(
      from n in Connection,
        join: c in assoc(n, :client),
        where: c.org_id == ^org_id and c.id == ^client_id and c.gstin == n.gstin
    )
  end

  def disconnect(scope, client_id) do
    with :ok <- authorize(scope, :manage_connectors),
         {:ok, client} <- Clients.get_client(scope.current_org.id, client_id) do
      Repo.delete_all(from c in Connection, where: c.client_id == ^client.id)
      :ok
    end
  end

  def account(connection) do
    with {:ok, current} <- refresh_connection(connection) do
      {:ok, account_fields(current)}
    end
  end

  # Only a provider rejection establishes that a new OTP is required.
  def session_expired?(connection, _now),
    do: connection.credentials["reauth_required"] == true

  def refresh_due?(connection, now \\ DateTime.utc_now()) do
    refreshed_at =
      case DateTime.from_iso8601(connection.credentials["refreshed_at"] || "") do
        {:ok, time, _} -> time
        _ -> connection.authorized_at
      end

    DateTime.diff(now, refreshed_at) >= 5 * 3600
  end

  defp account_fields(connection) do
    %{
      gstin: connection.gstin,
      username: connection.username,
      txn: connection.credentials["txn"],
      ip_address: connection.credentials["ip_address"]
    }
  end

  defp refresh_connection(connection, force? \\ false) do
    # Serialize refreshes for one account, including overlapping downloads and
    # the background job. Re-read after locking so stale callers reuse the result.
    # The provider call holds this row lock for at most its HTTP timeout.
    Repo.transact(
      fn ->
        with {:ok, current} <-
               Repo.fetch_one(
                 from c in Connection,
                   join: client in assoc(c, :client),
                   where:
                     c.id == ^connection.id and c.gstin == ^connection.gstin and
                       c.gstin == client.gstin,
                   lock: "FOR UPDATE OF g0"
               ) do
          force? = force? and current.updated_at == connection.updated_at
          {:ok, refresh_locked(current, force?)}
        end
      end,
      timeout: 45_000
    )
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp refresh_locked(connection, force?) do
    cond do
      session_expired?(connection, DateTime.utc_now()) ->
        {:error, :session_expired}

      not force? and not refresh_due?(connection) ->
        {:ok, connection}

      true ->
        case Whitebooks.refresh(account_fields(connection)) do
          {:ok, body} ->
            txn = Map.get(body, "txn", connection.credentials["txn"])

            if is_binary(txn) and txn != "" do
              credentials =
                Map.merge(connection.credentials, %{
                  "txn" => txn,
                  "refreshed_at" => DateTime.to_iso8601(DateTime.utc_now())
                })

              {:ok,
               connection
               |> Ecto.Changeset.change(credentials: credentials)
               |> Repo.update!(log: false)}
            else
              {:error, :unexpected_response}
            end

          {:error, reason} ->
            if authentication_error?(reason) do
              mark_reauthentication!(connection)
              {:error, :session_expired}
            else
              {:error, reason}
            end
        end
    end
  end

  defp authentication_error?({:provider, code}),
    do: code in ["WB_ERR_9503", "RET11407", "RET11408"]

  defp authentication_error?(_), do: false

  defp mark_reauthentication!(connection) do
    connection
    |> Ecto.Changeset.change(
      credentials: Map.put(connection.credentials, "reauth_required", true)
    )
    |> Repo.update!(log: false)
  end

  defp request(connection, call) do
    with {:ok, current} <- refresh_connection(connection) do
      case call.(account_fields(current)) do
        {:error, reason} = error ->
          if authentication_error?(reason) do
            with {:ok, refreshed} <- refresh_connection(current, true) do
              case call.(account_fields(refreshed)) do
                {:error, retry_reason} = retry_error ->
                  if authentication_error?(retry_reason) do
                    # A new OTP may have replaced this session while the call ran.
                    {:ok, result} =
                      Repo.transact(fn ->
                        latest =
                          Repo.one(
                            from c in Connection, where: c.id == ^refreshed.id, lock: "FOR UPDATE"
                          )

                        if latest && latest.updated_at == refreshed.updated_at do
                          mark_reauthentication!(latest)
                          {:ok, :session_expired}
                        else
                          {:ok, :unavailable}
                        end
                      end)

                    {:error, result}
                  else
                    retry_error
                  end

                success ->
                  success
              end
            end
          else
            error
          end

        success ->
          success
      end
    end
  end

  def list_notices(org_id, client_id, date) do
    with {:ok, connection} <- connection(org_id, client_id) do
      request(connection, &Whitebooks.list_notices(&1, date))
    end
  end

  def gstr2b(org_id, client_id, gstin, date) do
    with {:ok, connection} <- connection(org_id, client_id),
         true <- connection.gstin == gstin do
      request(connection, &Whitebooks.gstr2b(&1, date))
    else
      false -> {:error, :invalid_connection}
      error -> error
    end
  end

  def notice_details(org_id, client_id, reference) do
    with {:ok, connection} <- connection(org_id, client_id) do
      request(connection, &Whitebooks.notice_details(&1, reference))
    end
  end

  def download_document(org_id, client_id, gstin, document_id, issued_on) do
    with {:ok, connection} <- connection(org_id, client_id),
         true <- connection.gstin == gstin do
      request(connection, &Whitebooks.download_document(&1, document_id, issued_on))
    else
      false -> {:error, :invalid_connection}
      error -> error
    end
  end

  defdelegate lookup_taxpayer(gstin), to: Nila.Gst.Portal.Taxpayers, as: :lookup

  defp authorize(scope, capability),
    do: if(Policy.can?(scope, capability), do: :ok, else: {:error, :forbidden})

  defp ip_address do
    config = Application.get_env(:nila, Whitebooks, [])

    with ip when is_binary(ip) <- config[:ip_address],
         {:ok, _} <- :inet.parse_address(String.to_charlist(ip)) do
      {:ok, ip}
    else
      _ -> {:error, :not_configured}
    end
  end
end
