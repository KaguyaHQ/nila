defmodule Nila.Integrations.WhatsAppIngestWorker do
  use Oban.Worker, queue: :documents, max_attempts: 3

  alias Nila.Documents.Import
  alias Nila.Integrations

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"connection_id" => connection_id, "payload" => payload}}) do
    connection = Integrations.get_connection!(connection_id)
    token = Map.fetch!(connection.credentials, "access_token")

    with {:ok, attachments} <- whatsapp_adapter().normalize(payload, connection: connection) do
      Enum.each(attachments, fn attachment ->
        {:ok, bytes} = whatsapp_adapter().fetch_media(attachment.media_id, token)

        attrs =
          attachment
          |> Map.take([:filename, :content_type, :document_type])
          |> Map.put(:bytes, bytes)
          |> Map.put(:org_id, connection.org_id)

        {:ok, _document} = Import.import_document(attrs)
      end)

      :ok
    end
  end

  defp whatsapp_adapter do
    Application.get_env(:nila, :whatsapp_adapter, Nila.Integrations.WhatsApp)
  end
end
