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
        returning: true
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

  def account(connection) do
    if not session_expired?(connection, DateTime.utc_now()) do
      {:ok,
       %{
         gstin: connection.gstin,
         username: connection.username,
         txn: connection.credentials["txn"],
         ip_address: connection.credentials["ip_address"]
       }}
    else
      {:error, :session_expired}
    end
  end

  def session_expired?(connection, now),
    do: DateTime.diff(now, connection.authorized_at) >= 6 * 3600

  def list_notices(org_id, client_id, date) do
    with {:ok, connection} <- connection(org_id, client_id),
         {:ok, account} <- account(connection) do
      Whitebooks.list_notices(account, date)
    end
  end

  def notice_details(org_id, client_id, reference) do
    with {:ok, connection} <- connection(org_id, client_id),
         {:ok, account} <- account(connection) do
      Whitebooks.notice_details(account, reference)
    end
  end

  def download_document(org_id, client_id, gstin, document_id, issued_on) do
    with {:ok, connection} <- connection(org_id, client_id),
         true <- connection.gstin == gstin,
         {:ok, account} <- account(connection) do
      Whitebooks.download_document(account, document_id, issued_on)
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
