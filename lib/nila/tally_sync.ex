defmodule Nila.TallySync do
  @moduledoc "Durable, company-scoped snapshots read from Tally by a connector."

  import Ecto.Query

  alias Nila.Repo
  alias Nila.Gst.Sales.{Month, Months}
  alias Nila.TallyDevices.{Company, CompanyDevice, Device, SyncRun, SyncedMaster, SyncedVoucher}

  @max_records 1_000
  @voucher_numbering_methods_allowing_imported_numbers [
    "manual",
    "automatic (manual override)"
  ]

  @doc "Returns referenced ledger names absent from the latest stored Tally snapshot."
  def missing_ledgers(company_id, names) when is_integer(company_id) and is_list(names) do
    requested =
      names
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq_by(&String.downcase/1)

    normalized = Enum.map(requested, &String.downcase/1)

    found =
      from(m in SyncedMaster,
        where:
          m.company_id == ^company_id and m.kind == "ledger" and
            fragment("lower(?)", m.name) in ^normalized,
        select: fragment("lower(?)", m.name)
      )
      |> Repo.all()
      |> MapSet.new()

    Enum.reject(requested, &MapSet.member?(found, String.downcase(&1)))
  end

  @doc "Returns voucher types whose numbering configuration cannot preserve imported numbers."
  def voucher_numbering_issues(company_id, voucher_types)
      when is_integer(company_id) and is_list(voucher_types) do
    requested =
      voucher_types
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq_by(&String.downcase/1)

    methods =
      from(m in SyncedMaster,
        where:
          m.company_id == ^company_id and m.kind == "voucher_type" and
            fragment("lower(?)", m.name) in ^Enum.map(requested, &String.downcase/1),
        select: {fragment("lower(?)", m.name), m.data}
      )
      |> Repo.all()
      |> Map.new()

    Enum.flat_map(requested, fn voucher_type ->
      case methods[String.downcase(voucher_type)] do
        %{"numbering_method" => method} when is_binary(method) ->
          if String.downcase(String.trim(method)) in @voucher_numbering_methods_allowing_imported_numbers do
            []
          else
            [%{voucher_type: voucher_type, numbering_method: method}]
          end

        _missing ->
          [%{voucher_type: voucher_type, numbering_method: nil}]
      end
    end)
  end

  def india_today, do: DateTime.utc_now() |> DateTime.add(19_800, :second) |> DateTime.to_date()

  def financial_year_start(%Date{} = date),
    do: Date.new!(if(date.month < 4, do: date.year - 1, else: date.year), 4, 1)

  def start(%Device{} = device, company_identity, today \\ india_today(), opts \\ []) do
    Repo.transact(fn ->
      with %Company{} = company <-
             Repo.one(
               from route in CompanyDevice,
                 join: c in assoc(route, :company),
                 where:
                   route.device_id == ^device.id and route.is_open and c.org_id == ^device.org_id and
                     c.identity == ^company_identity,
                 select: c,
                 lock: "FOR UPDATE"
             ),
           :ok <- available_sync(company.id) do
        now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
        period_start = Keyword.get(opts, :period_start, financial_year_start(today))

        %SyncRun{
          org_id: device.org_id,
          device_id: device.id,
          company_id: company.id,
          period_start: period_start,
          period_end: today,
          started_at: now
        }
        |> Repo.insert()
        |> case do
          {:ok, run} -> {:ok, Repo.preload(run, :company)}
          error -> error
        end
      else
        nil -> {:error, :company_not_found}
        error -> error
      end
    end)
  end

  defp available_sync(company_id) do
    cutoff = DateTime.add(DateTime.utc_now(), -900, :second)

    Repo.update_all(
      from(run in SyncRun,
        where:
          run.company_id == ^company_id and run.status == "running" and run.started_at < ^cutoff
      ),
      set: [
        status: "failed",
        masters_status: "failed",
        vouchers_status: "failed",
        masters_error: "The connector sync timed out. Refresh again.",
        vouchers_error: "The connector sync timed out. Refresh again.",
        completed_at: DateTime.utc_now()
      ]
    )

    if Repo.exists?(
         from run in SyncRun, where: run.company_id == ^company_id and run.status == "running"
       ), do: {:error, :sync_in_progress}, else: :ok
  end

  def interrupt_running(
        device_id,
        connected_at \\ DateTime.utc_now(),
        cutoff \\ DateTime.utc_now()
      ) do
    Repo.update_all(
      from(run in SyncRun,
        join: device in Device,
        on: device.id == run.device_id,
        where:
          run.device_id == ^device_id and run.status == "running" and
            run.started_at <= ^cutoff and
            (is_nil(device.last_connected_at) or device.last_connected_at <= ^connected_at)
      ),
      set: [
        status: "failed",
        masters_status: "failed",
        vouchers_status: "failed",
        masters_error: "Nila Connector disconnected during refresh.",
        vouchers_error: "Nila Connector disconnected during refresh.",
        completed_at: DateTime.utc_now()
      ]
    )

    :ok
  end

  def coverage(org_id, company_id, period) do
    {:ok, from_date} = Date.from_iso8601(period <> "-01")
    to_date = Date.end_of_month(from_date)

    runs =
      Repo.all(
        from run in SyncRun,
          where:
            run.org_id == ^org_id and run.company_id == ^company_id and
              run.period_start <= ^to_date and run.period_end >= ^from_date,
          order_by: [desc: run.id]
      )

    relevant = List.first(runs)

    latest =
      Repo.one(
        from run in SyncRun,
          where: run.org_id == ^org_id and run.company_id == ^company_id,
          order_by: [desc: run.id],
          limit: 1
      )

    run =
      if latest && latest.status != "succeeded" && (is_nil(relevant) or latest.id > relevant.id),
        do: latest,
        else: relevant

    completed = Enum.find(runs, &(&1.status == "succeeded"))

    covered =
      not is_nil(run) and run.status == "succeeded" and
        Date.compare(run.period_start, from_date) != :gt and
        Date.compare(run.period_end, to_date) != :lt

    timed_out =
      run && run.status == "running" && DateTime.diff(DateTime.utc_now(), run.started_at) > 900

    %{
      status:
        if(timed_out,
          do: "failed",
          else:
            if(run,
              do: if(run.status == "partial", do: "failed", else: run.status),
              else: "not_synced"
            )
        ),
      run_id: run && run.id,
      period_start: run && run.period_start,
      period_end: run && run.period_end,
      last_completed_at: completed && completed.completed_at,
      error:
        if(timed_out,
          do: "The connector sync timed out. Refresh again.",
          else: run && (run.vouchers_error || run.masters_error)
        ),
      covered: covered
    }
  end

  def put_pipeline(%Device{} = device, run_id, pipeline, records, complete)
      when pipeline in [:masters, :vouchers] and is_list(records) and
             length(records) <= @max_records and is_boolean(complete) do
    Repo.transact(fn ->
      with %SyncRun{} = run <- lock_run(device, run_id),
           :ok <- ensure_pipeline_pending(run, pipeline),
           {:ok, rows} <- normalize_records(pipeline, run, records) do
        now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
        upsert_records(pipeline, rows, now)

        changes = pipeline_changes(pipeline, run, complete, now)

        with {:ok, updated_run} <- run |> Ecto.Changeset.change(changes) |> Repo.update(),
             :ok <- maybe_refresh_sales_month(updated_run, pipeline, complete) do
          {:ok, updated_run}
        end
      else
        nil -> {:error, :not_found}
        error -> error
      end
    end)
  end

  def put_pipeline(%Device{}, _run_id, _pipeline, _records, _complete),
    do: {:error, :invalid_records}

  def fail_pipeline(%Device{} = device, run_id, pipeline, error)
      when pipeline in [:masters, :vouchers] and is_binary(error) do
    Repo.transact(fn ->
      case lock_run(device, run_id) do
        %SyncRun{} = run ->
          now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
          message = error |> String.trim() |> String.slice(0, 500)

          run
          |> Ecto.Changeset.change(%{
            pipeline_status_field(pipeline) => "failed",
            error_field(pipeline) => message,
            status: if(other_status(run, pipeline) == "succeeded", do: "partial", else: "failed"),
            completed_at: now
          })
          |> Repo.update()

        nil ->
          {:error, :not_found}
      end
    end)
  end

  defp lock_run(device, run_id) do
    Repo.one(
      from r in SyncRun,
        where: r.id == ^run_id and r.device_id == ^device.id and r.org_id == ^device.org_id,
        lock: "FOR UPDATE"
    )
  end

  defp ensure_pipeline_pending(run, pipeline) do
    if run.status == "running" and
         Map.fetch!(run, pipeline_status_field(pipeline)) in ~w(pending running),
       do: :ok,
       else: {:error, :already_completed}
  end

  defp normalize_records(:masters, run, records) do
    map_records(records, &normalize_master(&1, run))
  end

  defp normalize_records(:vouchers, run, records) do
    map_records(records, &normalize_voucher(&1, run))
  end

  defp map_records(records, mapper) do
    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, rows} ->
      case mapper.(record) do
        {:ok, row} -> {:cont, {:ok, [row | rows]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp normalize_master(%{"kind" => kind, "identity" => identity, "name" => name} = item, run)
       when is_binary(kind) and is_binary(identity) and is_binary(name) do
    kind = String.downcase(String.trim(kind))
    identity = String.trim(identity)
    name = String.trim(name)

    if kind in ~w(ledger voucher_type stock_item) and valid?(identity, 300) and valid?(name, 300) do
      {:ok,
       %{
         org_id: run.org_id,
         company_id: run.company_id,
         last_seen_sync_id: run.id,
         kind: kind,
         identity: identity,
         name: name,
         tally_guid: optional(item["tally_guid"], 300),
         alter_id: optional(item["alter_id"], 100),
         data: safe_data(item["data"])
       }}
    else
      {:error, :invalid_records}
    end
  end

  defp normalize_master(_, _), do: {:error, :invalid_records}

  defp normalize_voucher(
         %{"identity" => identity, "date" => date, "voucher_type" => voucher_type} = item,
         run
       )
       when is_binary(identity) and is_binary(date) and is_binary(voucher_type) do
    with true <- valid?(identity, 300),
         true <- valid?(voucher_type, 200),
         {:ok, parsed_date} <- Date.from_iso8601(date),
         true <- Date.compare(parsed_date, run.period_start) != :lt,
         true <- Date.compare(parsed_date, run.period_end) != :gt do
      {:ok,
       %{
         org_id: run.org_id,
         company_id: run.company_id,
         last_seen_sync_id: run.id,
         identity: String.trim(identity),
         master_id: integer(item["master_id"]),
         tally_guid: optional(item["tally_guid"], 300),
         remote_id: optional(item["remote_id"], 300),
         date: parsed_date,
         voucher_type: String.trim(voucher_type),
         voucher_number: optional(item["voucher_number"], 200),
         narration: optional(item["narration"], 2_000),
         data: safe_data(item["data"])
       }}
    else
      _ -> {:error, :invalid_records}
    end
  end

  defp normalize_voucher(_, _), do: {:error, :invalid_records}

  defp upsert_records(:masters, rows, now) do
    rows = Enum.map(rows, &Map.merge(&1, %{inserted_at: now, updated_at: now}))

    Repo.insert_all(SyncedMaster, rows,
      conflict_target: [:company_id, :kind, :identity],
      on_conflict:
        {:replace, [:name, :tally_guid, :alter_id, :data, :last_seen_sync_id, :updated_at]}
    )
  end

  defp upsert_records(:vouchers, rows, now) do
    rows = Enum.map(rows, &Map.merge(&1, %{inserted_at: now, updated_at: now}))

    Repo.insert_all(SyncedVoucher, rows,
      conflict_target: [:company_id, :identity],
      on_conflict:
        {:replace,
         [
           :master_id,
           :tally_guid,
           :remote_id,
           :date,
           :voucher_type,
           :voucher_number,
           :narration,
           :data,
           :last_seen_sync_id,
           :updated_at
         ]}
    )
  end

  defp remove_stale(:masters, run) do
    from(m in SyncedMaster,
      where: m.company_id == ^run.company_id and m.last_seen_sync_id != ^run.id
    )
    |> Repo.delete_all()
  end

  defp remove_stale(:vouchers, run) do
    from(v in SyncedVoucher,
      where:
        v.company_id == ^run.company_id and v.date >= ^run.period_start and
          v.date <= ^run.period_end and v.last_seen_sync_id != ^run.id
    )
    |> Repo.delete_all()
  end

  defp pipeline_changes(pipeline, _run, false, _now) do
    %{pipeline_status_field(pipeline) => "running", status: "running"}
  end

  defp pipeline_changes(pipeline, run, true, now) do
    remove_stale(pipeline, run)
    count = pipeline_count(pipeline, run)

    %{pipeline_status_field(pipeline) => "succeeded", count_field(pipeline) => count}
    |> maybe_complete(run, pipeline, now)
  end

  defp pipeline_count(:masters, run) do
    Repo.aggregate(
      from(m in SyncedMaster,
        where: m.company_id == ^run.company_id and m.last_seen_sync_id == ^run.id
      ),
      :count
    )
  end

  defp pipeline_count(:vouchers, run) do
    Repo.aggregate(
      from(v in SyncedVoucher,
        where: v.company_id == ^run.company_id and v.last_seen_sync_id == ^run.id
      ),
      :count
    )
  end

  defp maybe_complete(changes, run, pipeline, now) do
    if other_status(run, pipeline) == "succeeded" do
      Map.merge(changes, %{status: "succeeded", completed_at: now})
    else
      Map.put(changes, :status, "running")
    end
  end

  defp other_status(run, :masters), do: run.vouchers_status
  defp other_status(run, :vouchers), do: run.masters_status
  defp pipeline_status_field(:masters), do: :masters_status
  defp pipeline_status_field(:vouchers), do: :vouchers_status
  defp count_field(:masters), do: :masters_count
  defp count_field(:vouchers), do: :vouchers_count
  defp error_field(:masters), do: :masters_error
  defp error_field(:vouchers), do: :vouchers_error

  defp maybe_refresh_sales_month(%SyncRun{} = run, :vouchers, true) do
    company = Company |> Repo.get!(run.company_id) |> Repo.preload(:client)

    if company.client do
      for date <- month_starts(run.period_start, run.period_end) do
        period = Calendar.strftime(date, "%Y-%m")

        {:ok, month} =
          Months.upsert(%{
            org_id: run.org_id,
            client_id: company.client.id,
            period: period
          })

        previous_sync_id = month.summary["tally_sync_id"]

        if is_nil(month.filed_at) and previous_sync_id != run.id do
          summary =
            Map.merge(month.summary || %{}, %{
              "tally_sync_id" => run.id,
              "tally_last_synced_at" => DateTime.to_iso8601(run.updated_at)
            })

          state = if month.state == "reviewed", do: "worked", else: month.state

          month
          |> Month.changeset(%{summary: summary, state: state})
          |> Repo.update!()
        end
      end
    end

    :ok
  end

  defp maybe_refresh_sales_month(%SyncRun{}, _pipeline, _complete), do: :ok

  defp month_starts(first, last) do
    Stream.unfold(Date.beginning_of_month(first), fn date ->
      if Date.compare(date, last) == :gt,
        do: nil,
        else: {date, Date.add(Date.end_of_month(date), 1)}
    end)
    |> Enum.to_list()
  end

  defp valid?(value, max),
    do: is_binary(value) and String.trim(value) != "" and byte_size(value) <= max

  defp optional(nil, _max), do: nil

  defp optional(value, max) when is_binary(value) and byte_size(value) <= max,
    do: value |> String.trim() |> then(&if(&1 == "", do: nil, else: &1))

  defp optional(_, _), do: nil
  defp integer(value) when is_integer(value) and value > 0, do: value
  defp integer(_), do: nil
  defp safe_data(value) when is_map(value), do: value
  defp safe_data(_), do: %{}
end
