defmodule Nila.Gst.Chase.CompletenessSender do
  use Oban.Worker, queue: :chase, max_attempts: 5

  alias Nila.Clients
  alias Nila.Gst.Chase
  alias Nila.Gst.Intake.{Confirmations, Dumps}
  alias Nila.Integrations
  alias Nila.Integrations.WhatsAppReply
  alias Nila.Orgs

  @quiet_seconds 300

  def enqueue(dump) do
    enqueue(
      %{org_id: dump.org_id, client_id: dump.client_id, period: dump.period},
      @quiet_seconds
    )
  end

  def enqueue_now(org_id, client_id, period) do
    enqueue(%{org_id: org_id, client_id: client_id, period: period}, 0)
  end

  defp enqueue(scope, schedule_in) do
    %{
      org_id: scope.org_id,
      client_id: scope.client_id,
      period: scope.period,
      ask_ref: Ecto.UUID.generate()
    }
    |> new(
      schedule_in: schedule_in,
      unique: [
        period: @quiet_seconds * 2,
        fields: [:worker, :args],
        keys: [:org_id, :client_id, :period],
        states: [:scheduled]
      ],
      replace: [scheduled: [:scheduled_at, :args]]
    )
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    org_id = args["org_id"]
    client_id = args["client_id"]
    period = args["period"]

    cond do
      processing?(org_id, client_id, period) ->
        {:snooze, @quiet_seconds}

      intake_needs_attention?(org_id, client_id, period) ->
        {:cancel, :sales_intake_needs_attention}

      Confirmations.status(org_id, client_id, period) == :complete ->
        :ok

      true ->
        send_request(org_id, client_id, period, args["ask_ref"])
    end
  end

  defp send_request(org_id, client_id, period, ask_ref) do
    with {:error, :not_found} <- Chase.fetch_ask_by_ref(org_id, ask_ref),
         {:ok, client} <- Clients.get_client(org_id, client_id),
         true <- client.chase_channel == "whatsapp" and is_binary(client.phone),
         %{} = connection <- Integrations.first_active_connection(org_id, "whatsapp"),
         template when is_binary(template) <-
           Application.get_env(:nila, :whatsapp_completeness_template),
         {:ok, yes_payload} <- WhatsAppReply.sign(ask_ref, "client_yes"),
         {:ok, no_payload} <- WhatsAppReply.sign(ask_ref, "client_no"),
         {:ok, response} <-
           send_whatsapp(
             connection,
             client.phone,
             month_label(period),
             template,
             yes_payload,
             no_payload
           ),
         {:ok, _ask} <-
           Chase.record_ask(%{org_id: org_id, client_id: client_id}, %{
             kind: "sales_completeness",
             period: period,
             body: Chase.draft(:sales_completeness, Orgs.get_org!(org_id), client, period),
             channel: "whatsapp",
             ask_ref: ask_ref,
             provider_ref: provider_ref(response)
           }) do
      :ok
    else
      {:ok, _existing_ask} -> :ok
      false -> {:cancel, :client_not_on_whatsapp}
      nil -> {:cancel, :whatsapp_completeness_not_configured}
      error -> error
    end
  end

  defp processing?(org_id, client_id, period),
    do: has_sales_status?(org_id, client_id, period, ~w(received extracting))

  defp intake_needs_attention?(org_id, client_id, period),
    do: has_sales_status?(org_id, client_id, period, ~w(failed held needs_confirmation))

  defp has_sales_status?(org_id, client_id, period, statuses) do
    org_id
    |> Dumps.list(client_id, period)
    |> Enum.any?(&(&1.kind == "sales" and &1.status in statuses))
  end

  defp provider_ref(%{"messages" => [%{"id" => id} | _]}), do: id
  defp provider_ref(_response), do: nil

  defp month_label(<<year::binary-size(4), "-", month::binary-size(2)>>) do
    Date.new!(String.to_integer(year), String.to_integer(month), 1)
    |> Calendar.strftime("%B %Y")
  end

  defp send_whatsapp(connection, recipient, period, template, yes_payload, no_payload) do
    result =
      whatsapp_adapter().send_completeness_request(
        connection,
        recipient,
        period,
        template,
        yes_payload,
        no_payload
      )

    case result do
      {:ok, _response} ->
        _ = Integrations.mark_connected(connection)
        result

      {:error, reason} ->
        _ = Integrations.mark_degraded(connection, reason)
        result
    end
  end

  defp whatsapp_adapter,
    do: Application.get_env(:nila, :whatsapp_adapter, Nila.Integrations.WhatsApp)
end
