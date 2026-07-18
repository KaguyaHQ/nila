defmodule Nila.Integrations.WhatsAppIngestWorker do
  use Oban.Worker, queue: :documents, max_attempts: 3

  alias Nila.Clients
  alias Nila.Clients.Client
  alias Nila.Gst.Arrivals
  alias Nila.Integrations

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"connection_id" => connection_id, "payload" => payload}}) do
    connection = Integrations.get_connection!(connection_id)
    token = Map.fetch!(connection.credentials, "access_token")

    with {:ok, attachments} <- whatsapp_adapter().normalize(payload, connection: connection) do
      attachments
      |> Enum.filter(&supported?/1)
      |> Enum.each(fn attachment ->
        {:ok, bytes} = whatsapp_adapter().fetch_media(attachment.media_id, token)
        sender = Client.normalize_phone(attachment.sender)

        client_id =
          case Clients.get_by_phone(connection.org_id, sender) do
            {:ok, client} -> client.id
            {:error, :not_found} -> nil
          end

        {:ok, _arrival} =
          Arrivals.ingest(
            %{org_id: connection.org_id, client_id: client_id},
            %{
              source: "whatsapp",
              source_ref: Map.get(attachment, :source_ref),
              sender: sender,
              filename: attachment.filename,
              content_type: attachment.content_type,
              bytes: bytes
            }
          )
      end)

      :ok
    end
  end

  defp supported?(%{content_type: "application/pdf"}), do: true
  defp supported?(%{content_type: "image/" <> _}), do: true
  defp supported?(_attachment), do: false

  defp whatsapp_adapter do
    Application.get_env(:nila, :whatsapp_adapter, Nila.Integrations.WhatsApp)
  end
end
