defmodule Nila.TallyJobs do
  @moduledoc "Durable, device-scoped work sent to Nila Connector."

  import Ecto.Query

  alias Nila.Repo
  alias Nila.TallySync
  alias Nila.TallyDevices.Company
  alias Nila.TallyDevices.Device
  alias Nila.TallyJobs.Job

  def enqueue_create_voucher(%Device{} = device, payload, opts \\ []) when is_map(payload) do
    case insert_job(device, "create_voucher", payload, opts) do
      {:ok, job, _disposition} -> {:ok, job}
      error -> error
    end
  end

  def enqueue_import_vouchers(company, xml, expected_count, opts \\ [])

  def enqueue_import_vouchers(
        %Company{is_open: true, device: %Device{} = device} = company,
        xml,
        expected_count,
        opts
      )
      when is_binary(xml) and is_integer(expected_count) and expected_count > 0 do
    if byte_size(xml) <= 750_000 do
      payload =
        %{
          "company" => company.name,
          "company_guid" => company.tally_guid,
          "xml" => xml,
          "expected_count" => expected_count
        }
        |> Map.merge(Keyword.get(opts, :metadata, %{}))

      insert_job(
        device,
        "import_vouchers",
        payload,
        opts
      )
    else
      {:error, :batch_too_large}
    end
  end

  def enqueue_import_vouchers(%Company{}, _xml, _expected_count, _opts),
    do: {:error, :company_not_open}

  @doc "Queues one durable job per logical voucher and safely retries definite failures."
  def enqueue_vouchers(%Company{} = company, items, opts \\ []) when is_list(items) do
    prefix = Keyword.fetch!(opts, :source_prefix)

    with true <- Enum.all?(items, &valid_voucher_item?/1),
         [] <-
           TallySync.voucher_numbering_issues(
             company.id,
             Enum.map(items, & &1.voucher_type)
           ) do
      Enum.reduce_while(items, {:ok, []}, fn item, {:ok, jobs} ->
        source_key = prefix <> item.source_id

        case enqueue_import_vouchers(company, item.xml, 1,
               source_key: source_key,
               retry_failed: true,
               metadata: %{
                 "source_id" => item.source_id,
                 "invoice_number" => item.invoice_number
               }
             ) do
          {:ok, job, disposition} -> {:cont, {:ok, [{job, disposition} | jobs]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, jobs} -> {:ok, Enum.reverse(jobs)}
        error -> error
      end
    else
      false -> {:error, :invalid_voucher_items}
      issues when is_list(issues) -> {:error, {:incompatible_voucher_numbering, issues}}
    end
  end

  def list_by_source_prefix(org_id, source_prefix)
      when is_integer(org_id) and is_binary(source_prefix) do
    from(j in Job,
      where: j.org_id == ^org_id and like(j.source_key, ^"#{source_prefix}%"),
      order_by: [asc: j.id]
    )
    |> Repo.all()
  end

  @doc "Requeues unknown voucher outcomes for read-only verification by the connector."
  def verify_indeterminate_by_source_prefix(org_id, source_prefix)
      when is_integer(org_id) and is_binary(source_prefix) do
    result =
      Repo.transact(fn ->
        jobs =
          from(j in Job,
            where:
              j.org_id == ^org_id and j.status == "indeterminate" and
                like(j.source_key, ^"#{source_prefix}%"),
            lock: "FOR UPDATE"
          )
          |> Repo.all()

        Enum.reduce_while(jobs, {:ok, []}, fn job, {:ok, verified} ->
          changes = %{
            status: "pending",
            payload: Map.put(job.payload, "mode", "verify_only"),
            started_at: nil,
            completed_at: nil,
            result: nil,
            error: nil
          }

          payload = Map.put(job.payload, "mode", "verify_only")

          case job
               |> Job.transition_changeset(Map.delete(changes, :payload))
               |> Ecto.Changeset.change(payload: payload)
               |> Repo.update() do
            {:ok, updated} -> {:cont, {:ok, [updated | verified]}}
            {:error, changeset} -> {:halt, {:error, changeset}}
          end
        end)
      end)

    case result do
      {:ok, jobs} ->
        jobs
        |> Enum.map(& &1.device_id)
        |> Enum.uniq()
        |> Enum.each(fn device_id ->
          Phoenix.PubSub.broadcast(Nila.PubSub, device_topic(device_id), :tally_job_available)
        end)

        if jobs != [], do: broadcast_org(org_id)
        {:ok, length(jobs)}

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
    result =
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

    case result do
      {:ok, %Job{} = job} ->
        broadcast_org(job.org_id)
        result

      _ ->
        result
    end
  end

  def get_job!(id), do: Repo.get!(Job, id)

  def interrupt_running(device_id, now \\ DateTime.utc_now()) when is_integer(device_id) do
    completed_at = DateTime.truncate(now, :microsecond)

    {count, _jobs} =
      from(job in Job, where: job.device_id == ^device_id and job.status == "running")
      |> Repo.update_all(
        set: [
          status: "indeterminate",
          result: nil,
          error: %{
            "kind" => "ConnectorDisconnected",
            "message" =>
              "The connector disconnected before Nila received a definitive Tally result."
          },
          completed_at: completed_at,
          updated_at: completed_at
        ]
      )

    {:ok, count}
  end

  def delivery_payload(%Job{} = job) do
    %{
      job_id: job.id,
      job_key: job.job_key,
      kind: job.kind,
      payload: job.payload
    }
  end

  def device_topic(device_id), do: "tally_jobs:device:#{device_id}"
  def org_topic(org_id), do: "tally_jobs:org:#{org_id}"
  def subscribe_org(org_id), do: Phoenix.PubSub.subscribe(Nila.PubSub, org_topic(org_id))

  defp insert_job(%Device{} = device, kind, payload, opts) do
    job_key = Keyword.get_lazy(opts, :job_key, &Ecto.UUID.generate/0)
    source_key = Keyword.get(opts, :source_key)

    changeset =
      %Job{org_id: device.org_id, device_id: device.id}
      |> Job.create_changeset(%{
        job_key: job_key,
        source_key: source_key,
        kind: kind,
        payload: payload
      })

    case Repo.insert(changeset) do
      {:ok, job} ->
        Phoenix.PubSub.broadcast(Nila.PubSub, device_topic(device.id), :tally_job_available)
        broadcast_org(job.org_id)
        {:ok, job, :created}

      {:error, _changeset} = error when is_binary(source_key) ->
        case Repo.fetch_by(Job, org_id: device.org_id, source_key: source_key) do
          {:ok, %Job{status: "failed"} = job} ->
            if Keyword.get(opts, :retry_failed, false) do
              job
              |> Ecto.Changeset.change(
                device_id: device.id,
                payload: payload,
                status: "pending",
                started_at: nil,
                completed_at: nil,
                result: nil,
                error: nil
              )
              |> Repo.update()
              |> case do
                {:ok, retried} ->
                  Phoenix.PubSub.broadcast(
                    Nila.PubSub,
                    device_topic(device.id),
                    :tally_job_available
                  )

                  broadcast_org(retried.org_id)

                  {:ok, retried, :retried}

                error ->
                  error
              end
            else
              {:ok, job, :existing}
            end

          {:ok, job} ->
            {:ok, job, :existing}

          {:error, :not_found} ->
            error
        end

      error ->
        error
    end
  end

  defp valid_voucher_item?(%{
         source_id: source_id,
         invoice_number: invoice_number,
         voucher_type: voucher_type,
         xml: xml
       }) do
    Enum.all?([source_id, invoice_number, voucher_type, xml], &(is_binary(&1) and &1 != ""))
  end

  defp valid_voucher_item?(_item), do: false

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

  defp broadcast_org(org_id) do
    Phoenix.PubSub.broadcast(Nila.PubSub, org_topic(org_id), :tally_jobs_changed)
  end
end
