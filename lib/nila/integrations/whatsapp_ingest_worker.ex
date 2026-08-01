defmodule Nila.Integrations.WhatsAppIngestWorker do
  use Oban.Worker, queue: :documents, max_attempts: 3

  require Logger

  alias Nila.Clients
  alias Nila.Clients.Client
  alias Nila.Gst.Chase
  alias Nila.Gst.Intake.{Arrivals, Confirmations, Dumps, Messages}
  alias Nila.Integrations
  alias Nila.Integrations.WhatsAppReply

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"connection_id" => connection_id, "payload" => payload}}) do
    connection = Integrations.get_connection!(connection_id)
    token = Map.fetch!(connection.credentials, "access_token")

    with {:ok, events} <- whatsapp_adapter().normalize(payload, connection: connection) do
      Enum.each(events, &handle_event(&1, connection, token))
      :ok
    end
  end

  defp handle_event(%{type: :media} = attachment, connection, token) do
    if supported?(attachment) do
      {:ok, bytes} = whatsapp_adapter().fetch_media(attachment.media_id, token)
      sender = Client.normalize_phone(attachment.sender)
      client_id = client_id(connection.org_id, sender)

      {:ok, _arrival} =
        Arrivals.ingest(
          %{org_id: connection.org_id, client_id: client_id},
          %{
            source: "whatsapp",
            source_ref: attachment.source_ref,
            sender: sender,
            filename: attachment.filename,
            content_type: attachment.content_type,
            bytes: bytes
          }
        )
    end
  end

  defp handle_event(%{type: :text} = message, connection, _token) do
    sender = Client.normalize_phone(message.sender)

    {:ok, _message} =
      Messages.record_whatsapp(
        %{org_id: connection.org_id, client_id: client_id(connection.org_id, sender)},
        %{
          source_ref: message.source_ref,
          provider_context_ref: message.provider_context_ref,
          sender: sender,
          body: message.body,
          received_at: DateTime.utc_now()
        }
      )
  end

  defp handle_event(%{type: :button_reply} = reply, connection, _token) do
    sender = Client.normalize_phone(reply.sender)

    with {:ok, %{ask_ref: ask_ref, decision: decision}} <- WhatsAppReply.verify(reply.payload),
         {:ok, ask} <- Chase.fetch_ask_by_ref(connection.org_id, ask_ref),
         true <- ask.kind == "sales_completeness" and ask.channel == "whatsapp",
         {:ok, client} <- Clients.get_client(connection.org_id, ask.client_id),
         true <- Client.normalize_phone(client.phone) == sender,
         false <- stale_ask?(ask),
         {:ok, _confirmation} <-
           Confirmations.record_client(
             %{org_id: connection.org_id},
             client.id,
             ask.period,
             %{
               decision: decision,
               channel: "whatsapp",
               source_ref: reply.source_ref,
               actor_phone: sender
             }
           ) do
      :ok
    else
      reason ->
        Logger.warning("Ignored invalid WhatsApp completeness reply", reason: inspect(reason))
        :ok
    end
  end

  defp handle_event(_unsupported, _connection, _token), do: :ok

  defp stale_ask?(ask) do
    ask.org_id
    |> Dumps.list(ask.client_id, ask.period)
    |> Enum.any?(fn dump ->
      dump.kind == "sales" and dump.status not in ~w(discarded after_filing) and
        DateTime.compare(dump.inserted_at, ask.inserted_at) == :gt
    end)
  end

  defp client_id(org_id, sender) do
    case Clients.get_by_phone(org_id, sender) do
      {:ok, client} -> client.id
      {:error, :not_found} -> nil
    end
  end

  defp supported?(%{content_type: "application/pdf"}), do: true
  defp supported?(%{content_type: "image/" <> _}), do: true
  defp supported?(_attachment), do: false

  defp whatsapp_adapter do
    Application.get_env(:nila, :whatsapp_adapter, Nila.Integrations.WhatsApp)
  end
end
