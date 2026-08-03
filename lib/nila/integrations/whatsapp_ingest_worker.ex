defmodule Nila.Integrations.WhatsAppIngestWorker do
  use Oban.Worker, queue: :whatsapp, max_attempts: 3

  require Logger

  alias Nila.Integrations
  alias Nila.Integrations.WhatsAppEventWorker
  alias Nila.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"connection_id" => connection_id, "payload" => payload}}) do
    connection = Integrations.get_connection!(connection_id)

    with {:ok, events} <- whatsapp_adapter().normalize(payload, connection: connection),
         {:ok, _jobs} <- enqueue_events(connection.id, events) do
      Logger.info("WhatsApp webhook dispatched",
        connection_id: connection.id,
        event_count: length(events)
      )

      :ok
    else
      {:error, reason} = error ->
        _ = Integrations.mark_degraded(connection, reason)

        Logger.warning("WhatsApp webhook dispatch failed",
          connection_id: connection.id,
          reason: inspect(reason)
        )

        error
    end
  end

  defp enqueue_events(connection_id, events) do
    multi =
      events
      |> Enum.with_index()
      |> Enum.reduce(Ecto.Multi.new(), fn {event, index}, multi ->
        changeset =
          WhatsAppEventWorker.new(
            %{connection_id: connection_id, event: serialize_event(event)},
            unique: [period: {30, :day}, fields: [:worker, :args]]
          )

        Oban.insert(multi, {:whatsapp_event, index}, changeset)
      end)

    case Repo.transaction(multi) do
      {:ok, jobs} -> {:ok, jobs}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  defp serialize_event(event) do
    Map.new(event, fn
      {key, value} when is_atom(value) and not is_nil(value) ->
        {to_string(key), to_string(value)}

      {key, value} ->
        {to_string(key), value}
    end)
  end

  defp whatsapp_adapter do
    Application.get_env(:nila, :whatsapp_adapter, Nila.Integrations.WhatsApp)
  end
end
