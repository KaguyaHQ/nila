defmodule Nila.Gst.Chase.Sender do
  use Oban.Worker, queue: :chase, max_attempts: 5

  require Logger

  alias Nila.Clients
  alias Nila.Gst.Chase
  alias Nila.Integrations
  alias Nila.Orgs

  def enqueue(%{draft: %{kind: kind, body: body}} = row) do
    %{
      org_id: row.org_id,
      client_id: row.client_id,
      period: row.period,
      kind: kind,
      body: body,
      channel: row.chase_channel
    }
    |> new(
      unique: [
        period: {1, :day},
        fields: [:args, :worker],
        keys: [:org_id, :client_id, :period, :channel]
      ]
    )
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    org_id = args["org_id"]
    client_id = args["client_id"]
    channel = args["channel"]

    with {:ok, client} <- Clients.get_client(org_id, client_id),
         true <- client.chase_channel == channel and channel != "none",
         org <- Orgs.get_org!(org_id),
         {:ok, delivery} <- deliver(channel, org, client, args),
         {:ok, _ask} <- record_ask(args, delivery) do
      Logger.info("GST chase sent",
        org_id: org_id,
        client_id: client_id,
        period: args["period"],
        channel: channel
      )

      :ok
    else
      false ->
        Logger.info("GST chase skipped after consent changed",
          org_id: org_id,
          client_id: client_id,
          period: args["period"],
          channel: channel
        )

        :ok

      {:error, reason} ->
        Logger.warning("GST chase send failed",
          org_id: org_id,
          client_id: client_id,
          period: args["period"],
          channel: channel,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp deliver("whatsapp", org, client, args) do
    with %{} = connection <- Integrations.first_active_connection(org.id, "whatsapp"),
         template when is_binary(template) <- Application.get_env(:nila, :whatsapp_chase_template) do
      result = whatsapp_adapter().send_message(connection, client.phone, args["body"], template)
      track_whatsapp_health(result, connection)
    else
      nil -> {:error, :no_whatsapp_connection_or_template}
    end
  end

  defp deliver("email", org, client, args) do
    with %{} = connection <- Integrations.first_active_email_connection(org.id),
         {:ok, adapter} <- Integrations.fetch_adapter(connection.provider),
         {:ok, connection} <- Integrations.ensure_token(connection) do
      adapter.send_message(connection, client.email, %{
        subject: "Documents for #{month_label(args["period"])} GST — #{org.name}",
        body: args["body"]
      })
    else
      nil -> {:error, :no_email_connection}
      error -> error
    end
  end

  defp record_ask(args, delivery) do
    Chase.record_ask(
      %{org_id: args["org_id"], client_id: args["client_id"]},
      %{
        kind: args["kind"],
        period: args["period"],
        body: args["body"],
        channel: args["channel"],
        provider_ref: provider_ref(delivery)
      }
    )
  end

  defp provider_ref(%{"messages" => [%{"id" => id} | _]}), do: id
  defp provider_ref(%{"id" => id}), do: id
  defp provider_ref(_delivery), do: nil

  defp month_label(<<year::binary-size(4), "-", month::binary-size(2)>>) do
    Date.new!(String.to_integer(year), String.to_integer(month), 1)
    |> Elixir.Calendar.strftime("%B %Y")
  end

  defp track_whatsapp_health({:ok, _response} = result, connection) do
    _ = Integrations.mark_connected(connection)
    result
  end

  defp track_whatsapp_health({:error, reason} = error, connection) do
    _ = Integrations.mark_degraded(connection, reason)
    error
  end

  defp whatsapp_adapter,
    do: Application.get_env(:nila, :whatsapp_adapter, Nila.Integrations.WhatsApp)
end
