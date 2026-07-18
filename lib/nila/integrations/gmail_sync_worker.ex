defmodule Nila.Integrations.GmailSyncWorker do
  use Oban.Worker, queue: :documents, max_attempts: 3

  alias Nila.Clients
  alias Nila.Clients.Client
  alias Nila.Gst.Arrivals
  alias Nila.Integrations

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"connection_id" => connection_id}}) do
    connection = Integrations.get_connection!(connection_id)

    with {:ok, connection} <- Integrations.ensure_gmail_access_token(connection),
         {:ok, attachments} <- gmail_adapter().sync(connection) do
      attachments
      |> Enum.filter(&supported?/1)
      |> Enum.each(fn attachment ->
        sender = Client.normalize_email(attachment.sender)

        case Clients.get_by_email(connection.org_id, sender) do
          {:ok, client} ->
            {:ok, _arrival} =
              Arrivals.ingest(
                %{org_id: connection.org_id, client_id: client.id},
                %{
                  source: "email",
                  source_ref: Map.get(attachment, :source_ref),
                  sender: sender,
                  filename: attachment.filename,
                  content_type: attachment.content_type,
                  bytes: attachment.bytes
                }
              )

          {:error, :not_found} ->
            :ok
        end
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

  defp supported?(%{content_type: "application/pdf"}), do: true
  defp supported?(%{content_type: "image/" <> _}), do: true
  defp supported?(_attachment), do: false

  defp gmail_adapter do
    Application.get_env(:nila, :gmail_adapter, Nila.Integrations.Gmail)
  end
end
