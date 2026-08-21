defmodule Nila.Dev.TallySimulator do
  @moduledoc false

  use GenServer

  import Ecto.Query

  alias Nila.Orgs.Org
  alias Nila.Repo
  alias Nila.TallyDevices
  alias Nila.TallyDevices.Device
  alias Nila.TallyJobs
  alias NilaWeb.Presence

  @device_name "Development Tally"
  @reconcile_interval :timer.seconds(2)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def sync(server \\ __MODULE__), do: GenServer.call(server, :sync)
  def drain(server \\ __MODULE__), do: GenServer.call(server, :drain)

  @impl true
  def init(opts) do
    state = %{
      company_name: Keyword.fetch!(opts, :company_name),
      gstin: Keyword.fetch!(opts, :gstin),
      org_ids: Keyword.get(opts, :org_ids),
      devices: %{}
    }

    {:ok, state, {:continue, :sync}}
  end

  @impl true
  def handle_continue(:sync, state), do: {:noreply, state |> reconcile() |> schedule_reconcile()}

  @impl true
  def handle_call(:sync, _from, state) do
    state = reconcile(state)
    {:reply, :ok, state}
  end

  def handle_call(:drain, _from, state) do
    drain_jobs(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:reconcile, state),
    do: {:noreply, state |> reconcile() |> schedule_reconcile()}

  def handle_info(:tally_job_available, state) do
    drain_jobs(state)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp reconcile(state) do
    Enum.reduce(orgs(state.org_ids), state, &ensure_org/2)
  end

  defp schedule_reconcile(state) do
    Process.send_after(self(), :reconcile, @reconcile_interval)
    state
  end

  defp orgs(nil),
    do: Repo.all(from org in Org, where: org.status == "active", order_by: [asc: org.id])

  defp orgs(org_ids) do
    Repo.all(
      from org in Org,
        where: org.status == "active" and org.id in ^org_ids,
        order_by: [asc: org.id]
    )
  end

  defp ensure_org(%Org{} = org, state) do
    if Map.has_key?(state.devices, org.id) do
      state
    else
      with {:ok, device} <- get_or_create_device(org),
           {:ok, _device} <- TallyDevices.mark_connected(device),
           {:ok, _jobs} <- TallyJobs.interrupt_running(device.id),
           {:ok, _companies} <-
             TallyDevices.report_companies(device, [
               %{
                 "name" => state.company_name,
                 "tally_guid" => "dev-tally-#{org.id}",
                 "gstin" => state.gstin
               }
             ]),
           {:ok, _presence} <- track_presence(org, device) do
        :ok = Phoenix.PubSub.subscribe(Nila.PubSub, TallyJobs.device_topic(device.id))
        send(self(), :tally_job_available)
        put_in(state, [:devices, org.id], device.id)
      else
        _error -> state
      end
    end
  end

  defp get_or_create_device(org) do
    case Repo.one(
           from device in Device,
             where:
               device.org_id == ^org.id and device.name == ^@device_name and
                 is_nil(device.revoked_at),
             order_by: [desc: device.id],
             limit: 1
         ) do
      %Device{} = device ->
        {:ok, device}

      nil ->
        case TallyDevices.create_device(org, %{name: @device_name}) do
          {:ok, device, _unused_token} -> {:ok, device}
          error -> error
        end
    end
  end

  defp track_presence(org, device) do
    Presence.track(
      self(),
      "tally_devices:#{org.id}",
      Integer.to_string(device.id),
      %{
        device_id: device.id,
        name: device.name,
        connector_version: "development",
        connected_at: DateTime.utc_now() |> DateTime.to_unix()
      }
    )
  end

  defp drain_jobs(state) do
    Enum.each(state.devices, fn {_org_id, device_id} -> drain_device(device_id) end)
  end

  defp drain_device(device_id) do
    case TallyJobs.claim_next(device_id) do
      {:ok, nil} ->
        :ok

      {:ok, job} ->
        expected = job.payload["expected_count"] || 1

        {:ok, _job} =
          TallyJobs.complete(device_id, job.id, "succeeded", %{
            "created" => expected,
            "altered" => 0,
            "combined" => 0,
            "ignored" => 0,
            "errors" => 0,
            "exceptions" => 0,
            "line_errors" => []
          })

        drain_device(device_id)

      {:error, _reason} ->
        :ok
    end
  end
end
