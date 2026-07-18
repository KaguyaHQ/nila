defmodule Nila.Gst.ChaseSender do
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
         {:ok, _delivery} <- deliver(channel, org, client, args),
         {:ok, _ask} <- record_ask(args) do
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
      whatsapp_adapter().send_message(connection, client.phone, args["body"], template)
    else
      nil -> {:error, :no_whatsapp_connection_or_template}
    end
  end

  defp deliver("email", org, client, args) do
    with %{} = connection <- Integrations.first_active_connection(org.id, "gmail"),
         {:ok, connection} <- Integrations.ensure_gmail_access_token(connection) do
      gmail_adapter().send_message(connection, client.email, %{
        subject: "Documents for #{month_label(args["period"])} GST — #{org.name}",
        body: args["body"]
      })
    else
      nil -> {:error, :no_gmail_connection}
      error -> error
    end
  end

  defp record_ask(args) do
    Chase.record_ask(
      %{org_id: args["org_id"], client_id: args["client_id"]},
      %{
        kind: args["kind"],
        period: args["period"],
        body: args["body"],
        channel: args["channel"]
      }
    )
  end

  defp month_label(<<year::binary-size(4), "-", month::binary-size(2)>>) do
    Date.new!(String.to_integer(year), String.to_integer(month), 1)
    |> Elixir.Calendar.strftime("%B %Y")
  end

  defp whatsapp_adapter,
    do: Application.get_env(:nila, :whatsapp_adapter, Nila.Integrations.WhatsApp)

  defp gmail_adapter,
    do: Application.get_env(:nila, :gmail_adapter, Nila.Integrations.Gmail)
end
