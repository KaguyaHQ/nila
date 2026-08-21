defmodule Mix.Tasks.Nila.ExtractionTiming do
  @shortdoc "Prints the persisted timeline for a GST extraction dump"

  @moduledoc """
  Reconstructs a dump's post-upload processing timeline from Postgres.

      mix nila.extraction_timing <dump_id>

  The clock begins when the dump row is recorded, after the browser has uploaded
  the source file. The task is read-only and makes no provider calls. Completed
  Oban jobs may already have been pruned; when present, their timestamps split
  queue time from setup and finalization.
  """

  use Mix.Task

  import Ecto.Query, only: [from: 2]

  alias Nila.Gst.Intake.{Dump, ExtractionAttempts}
  alias Nila.Repo

  @impl Mix.Task
  def run([id]) do
    Mix.Task.run("app.start")
    dump_id = parse_id!(id)

    case Repo.fetch(Dump, dump_id) do
      {:ok, dump} -> print_timeline(dump, ExtractionAttempts.list_for_dump(dump_id), job(dump_id))
      {:error, :not_found} -> Mix.raise("GST dump #{dump_id} not found")
    end
  end

  def run(_args), do: Mix.raise("usage: mix nila.extraction_timing <dump_id>")

  defp parse_id!(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> id
      _invalid -> Mix.raise("dump_id must be a positive integer")
    end
  end

  defp job(dump_id) do
    Repo.one(
      from j in Oban.Job,
        where: fragment("?->>'dump_id' = ?", j.args, ^to_string(dump_id)),
        order_by: [desc: j.id],
        limit: 1
    )
  end

  defp print_timeline(dump, attempts, job) do
    finish = finish_time(dump, job)
    total_ms = elapsed_ms(dump.inserted_at, finish)
    original_name = dump.meta["original_name"] || Path.basename(List.first(dump.file_keys) || "")

    Mix.shell().info("dump #{dump.id} · #{dump.kind} · #{dump.status} · #{original_name}")
    Mix.shell().info("post-upload total  #{duration(total_ms)}")

    attempts
    |> timeline(dump.inserted_at, job, finish)
    |> Enum.each(fn {label, milliseconds} ->
      Mix.shell().info(
        "  #{String.pad_trailing(label, 28)} #{duration(milliseconds)}#{share(milliseconds, total_ms)}"
      )
    end)
  end

  defp timeline(attempts, dump_started, job, finish) do
    {rows, cursor} = before_attempts(attempts, dump_started, job)

    {rows, cursor} =
      Enum.reduce(attempts, {rows, cursor}, fn attempt, {rows, cursor} ->
        gap = gap_row(cursor, attempt.started_at, "between provider stages")
        stage = attempt.request_metadata["stage"] || "provider call"
        completed_at = attempt.completed_at || attempt.started_at
        duration_ms = attempt.duration_ms || elapsed_ms(attempt.started_at, completed_at)

        {rows ++ gap ++ [{stage, duration_ms}], completed_at}
      end)

    rows ++ gap_row(cursor, finish, "persist and finalize")
  end

  defp before_attempts([], dump_started, _job), do: {[], dump_started}

  defp before_attempts([first | _], dump_started, nil) do
    {gap_row(dump_started, first.started_at, "queue, load and render"), first.started_at}
  end

  defp before_attempts([first | _], dump_started, job) do
    attempted_at = job.attempted_at || job.scheduled_at || job.inserted_at

    rows =
      gap_row(dump_started, attempted_at, "queue") ++
        gap_row(attempted_at, first.started_at, "load and render")

    {rows, first.started_at}
  end

  defp gap_row(nil, _finish, _label), do: []
  defp gap_row(_start, nil, _label), do: []

  defp gap_row(start, finish, label) do
    case elapsed_ms(start, finish) do
      milliseconds when milliseconds > 0 -> [{label, milliseconds}]
      _zero_or_clock_skew -> []
    end
  end

  defp finish_time(_dump, %{completed_at: completed_at}) when not is_nil(completed_at),
    do: completed_at

  defp finish_time(dump, _job), do: dump.updated_at

  defp elapsed_ms(start, finish), do: DateTime.diff(finish, start, :millisecond)

  defp duration(milliseconds) when milliseconds < 1_000, do: "#{milliseconds}ms"

  defp duration(milliseconds) do
    :erlang.float_to_binary(milliseconds / 1_000, decimals: 3) <> "s"
  end

  defp share(_milliseconds, total_ms) when total_ms <= 0, do: ""

  defp share(milliseconds, total_ms) do
    percentage = Float.round(milliseconds / total_ms * 100, 1)
    "  #{percentage}%"
  end
end
