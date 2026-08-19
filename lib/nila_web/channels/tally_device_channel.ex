defmodule NilaWeb.TallyDeviceChannel do
  use NilaWeb, :channel

  alias Nila.TallyDevices
  alias Nila.TallyJobs
  alias NilaWeb.Presence

  @impl true
  def join("tally_device:" <> device_id, payload, socket) do
    authenticated_device = socket.assigns.device
    connected_at = DateTime.utc_now()

    with true <- device_id == Integer.to_string(authenticated_device.id),
         %{} = device <- TallyDevices.get_active_device(authenticated_device.id),
         {:ok, device} <- TallyDevices.mark_connected(device, connected_at),
         {:ok, _interrupted_jobs} <- TallyJobs.interrupt_running(device.id, connected_at),
         {:ok, _companies} <-
           TallyDevices.report_companies(device, companies(payload), connected_at),
         {:ok, _presence} <-
           Presence.track(
             self(),
             "tally_devices:#{device.org_id}",
             Integer.to_string(device.id),
             %{
               device_id: device.id,
               name: device.name,
               connector_version: connector_version(payload),
               connected_at: DateTime.to_unix(connected_at)
             }
           ) do
      :ok = Phoenix.PubSub.subscribe(Nila.PubSub, TallyJobs.device_topic(device.id))
      send(self(), :deliver_tally_jobs)

      socket =
        socket
        |> assign(:device, device)
        |> assign(:connected_at, connected_at)

      {:ok, %{device_id: device.id, org_id: device.org_id}, socket}
    else
      false -> {:error, %{reason: "unauthorized"}}
      nil -> {:error, %{reason: "unauthorized"}}
      {:error, _reason} -> {:error, %{reason: "unavailable"}}
    end
  end

  @impl true
  def handle_in("ping", _payload, socket), do: {:reply, {:ok, %{online: true}}, socket}

  def handle_in(
        "job_result",
        %{"job_id" => job_id, "status" => status, "details" => details},
        socket
      )
      when is_integer(job_id) and status in ["succeeded", "failed", "indeterminate"] and
             is_map(details) do
    case TallyJobs.complete(socket.assigns.device.id, job_id, status, details) do
      {:ok, _job} ->
        send(self(), :deliver_tally_jobs)
        {:reply, :ok, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  def handle_in("job_result", _payload, socket),
    do: {:reply, {:error, %{reason: "invalid_result"}}, socket}

  @impl true
  def terminate(_reason, %{assigns: %{device: device, connected_at: connected_at}}) do
    TallyDevices.mark_companies_closed(device.id, connected_at)
  end

  @impl true
  def handle_info(:tally_job_available, socket) do
    send(self(), :deliver_tally_jobs)
    {:noreply, socket}
  end

  def handle_info(:deliver_tally_jobs, socket) do
    case TallyJobs.claim_next(socket.assigns.device.id) do
      {:ok, nil} ->
        {:noreply, socket}

      {:ok, job} ->
        push(socket, "job", TallyJobs.delivery_payload(job))
        {:noreply, socket}

      {:error, _reason} ->
        {:stop, :job_delivery_failed, socket}
    end
  end

  defp connector_version(%{"connector_version" => version})
       when is_binary(version) and byte_size(version) <= 64,
       do: version

  defp connector_version(_payload), do: nil

  defp companies(%{"companies" => companies}) when is_list(companies), do: companies
  defp companies(_payload), do: []
end
