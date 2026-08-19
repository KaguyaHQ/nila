defmodule Nila.TallyJobs do
  @moduledoc "Durable, device-scoped work sent to Nila Connector."

  import Ecto.Query

  alias Nila.Repo
  alias Nila.TallyDevices.Device
  alias Nila.TallyJobs.Job

  def enqueue_create_voucher(%Device{} = device, payload, opts \\ []) when is_map(payload) do
    job_key = Keyword.get_lazy(opts, :job_key, &Ecto.UUID.generate/0)

    changeset =
      %Job{org_id: device.org_id, device_id: device.id}
      |> Job.create_changeset(%{
        job_key: job_key,
        kind: "create_voucher",
        payload: payload
      })

    case Repo.insert(changeset) do
      {:ok, job} ->
        Phoenix.PubSub.broadcast(Nila.PubSub, device_topic(device.id), :tally_job_available)
        {:ok, job}

      error ->
        error
    end
  end

  def claim_next(device_id, now \\ DateTime.utc_now()) when is_integer(device_id) do
    Repo.transact(fn ->
      case Repo.one(
             from job in Job,
               where: job.device_id == ^device_id and job.status == "pending",
               order_by: [asc: job.id],
               limit: 1,
               lock: "FOR UPDATE SKIP LOCKED"
           ) do
        nil ->
          {:ok, nil}

        job ->
          job
          |> Job.transition_changeset(%{
            status: "running",
            attempts: job.attempts + 1,
            started_at: DateTime.truncate(now, :microsecond)
          })
          |> Repo.update()
      end
    end)
  end

  def complete(device_id, job_id, status, details, now \\ DateTime.utc_now())
      when status in ["succeeded", "failed", "indeterminate"] and is_map(details) do
    Repo.transact(fn ->
      with %Job{} = job <-
             Repo.one(
               from job in Job,
                 where:
                   job.id == ^job_id and job.device_id == ^device_id and
                     job.status == "running",
                 lock: "FOR UPDATE"
             ) || {:error, :not_running},
           attrs = completion_attrs(status, details, now),
           {:ok, completed} <- job |> Job.transition_changeset(attrs) |> Repo.update() do
        {:ok, completed}
      end
    end)
  end

  def get_job!(id), do: Repo.get!(Job, id)

  def delivery_payload(%Job{} = job) do
    %{
      job_id: job.id,
      job_key: job.job_key,
      kind: job.kind,
      payload: job.payload
    }
  end

  def device_topic(device_id), do: "tally_jobs:device:#{device_id}"

  defp completion_attrs("succeeded", result, now) do
    %{
      status: "succeeded",
      result: result,
      error: nil,
      completed_at: DateTime.truncate(now, :microsecond)
    }
  end

  defp completion_attrs("failed", error, now) do
    %{
      status: "failed",
      result: nil,
      error: error,
      completed_at: DateTime.truncate(now, :microsecond)
    }
  end

  defp completion_attrs("indeterminate", error, now) do
    %{
      status: "indeterminate",
      result: nil,
      error: error,
      completed_at: DateTime.truncate(now, :microsecond)
    }
  end
end
