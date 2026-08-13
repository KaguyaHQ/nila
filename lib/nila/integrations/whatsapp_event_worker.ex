defmodule Nila.Integrations.WhatsAppEventWorker do
  use Oban.Worker, queue: :whatsapp, max_attempts: 3

  require Logger

  alias Nila.Clients
  alias Nila.Clients.Client
  alias Nila.Gst.Intake.{Arrivals, Messages}
  alias Nila.Integrations

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"connection_id" => connection_id, "event" => event}}) do
    connection = Integrations.get_connection!(connection_id)

    case handle_event(event, connection) do
      :ok ->
        _ = Integrations.mark_received(connection)
        mark_connected_after_success(event, connection)
        :ok

      {:error, reason} = error ->
        _ = Integrations.mark_degraded(connection, reason)

        Logger.warning("WhatsApp event processing failed",
          connection_id: connection.id,
          event_type: event["type"],
          source_ref: event["source_ref"],
          reason: inspect(reason)
        )

        error
    end
  end

  defp handle_event(%{"type" => "media"} = attachment, connection) do
    if supported?(attachment) do
      with {:ok, token} <- access_token(connection),
           {:ok, bytes} <- whatsapp_adapter().fetch_media(attachment["media_id"], token),
           sender when is_binary(sender) <- Client.normalize_phone(attachment["sender"]),
           {:ok, _arrival} <-
             Arrivals.ingest(
               %{org_id: connection.org_id, client_id: client_id(connection.org_id, sender)},
               %{
                 source: "whatsapp",
                 source_ref: attachment["source_ref"],
                 sender: sender,
                 filename: attachment["filename"],
                 content_type: attachment["content_type"],
                 bytes: bytes
               }
             ) do
        :ok
      else
        nil -> {:error, :missing_sender}
        error -> error
      end
    else
      :ok
    end
  end

  defp handle_event(%{"type" => "text"} = message, connection) do
    sender = Client.normalize_phone(message["sender"])

    case Messages.record_whatsapp(
           %{org_id: connection.org_id, client_id: client_id(connection.org_id, sender)},
           %{
             source_ref: message["source_ref"],
             provider_context_ref: message["provider_context_ref"],
             sender: sender,
             body: message["body"],
             received_at: DateTime.utc_now()
           }
         ) do
      {:ok, _message} -> :ok
      error -> error
    end
  end

  defp handle_event(_unsupported, _connection), do: :ok

  defp mark_connected_after_success(%{"type" => "media"}, connection) do
    _ = Integrations.mark_connected(connection)
    :ok
  end

  defp mark_connected_after_success(_event, _connection), do: :ok

  defp access_token(%{credentials: %{"access_token" => token}})
       when is_binary(token) and token != "",
       do: {:ok, token}

  defp access_token(_connection), do: {:error, :missing_access_token}

  defp client_id(org_id, sender) do
    case Clients.get_by_phone(org_id, sender) do
      {:ok, client} -> client.id
      {:error, :not_found} -> nil
    end
  end

  defp supported?(%{"content_type" => "application/pdf"}), do: true
  defp supported?(%{"content_type" => "image/" <> _}), do: true
  defp supported?(_attachment), do: false

  defp whatsapp_adapter do
    Application.get_env(:nila, :whatsapp_adapter, Nila.Integrations.WhatsApp)
  end
end
