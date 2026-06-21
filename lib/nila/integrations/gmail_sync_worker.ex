defmodule Nila.Integrations.GmailSyncWorker do
  use Oban.Worker, queue: :documents, max_attempts: 3

  alias Nila.Documents.Import
  alias Nila.Integrations

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"connection_id" => connection_id}}) do
    connection = Integrations.get_connection!(connection_id)

    with {:ok, connection} <- ensure_access_token(connection),
         {:ok, attachments} <- gmail_adapter().sync(connection) do
      Enum.each(attachments, fn attachment ->
        attrs =
          attachment
          |> Map.take([:filename, :bytes, :content_type, :document_type])
          |> Map.put(:org_id, connection.org_id)

        {:ok, _document} = Import.import_document(attrs)
      end)

      {:ok, _connection} = Integrations.mark_synced(connection)
      :ok
    else
      {:error, reason} = error ->
        {:ok, _connection} = Integrations.mark_error(connection, reason)
        error

      reason ->
        {:ok, _connection} = Integrations.mark_error(connection, reason)
        {:error, reason}
    end
  end

  defp ensure_access_token(%{credentials: credentials} = connection) do
    if token_fresh?(credentials) do
      {:ok, connection}
    else
      refresh_token = Map.fetch!(credentials, "refresh_token")

      with {:ok, refreshed} <- gmail_adapter().refresh_token(refresh_token),
           credentials <- Map.merge(credentials, refreshed),
           {:ok, connection} <- Integrations.update_credentials(connection, credentials) do
        {:ok, connection}
      end
    end
  end

  defp token_fresh?(%{"access_token" => access_token, "expires_at" => expires_at})
       when is_binary(access_token) and is_binary(expires_at) do
    case DateTime.from_iso8601(expires_at) do
      {:ok, expires_at, _offset} ->
        DateTime.compare(expires_at, DateTime.add(DateTime.utc_now(), 60)) == :gt

      _error ->
        false
    end
  end

  defp token_fresh?(_credentials), do: false

  defp gmail_adapter do
    Application.get_env(:nila, :gmail_adapter, Nila.Integrations.Gmail)
  end
end
