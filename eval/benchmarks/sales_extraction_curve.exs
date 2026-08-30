defmodule Nila.MeasureSalesExtractionCurve do
  @moduledoc false

  alias Nila.Gst.Extraction.Sales.Vision
  alias Nila.Gst.Extraction.OpenAICompatibleChatFinch

  @log_path "tmp/sales-extraction-curve.jsonl"

  def run(["history"]) do
    start_repo!()

    sql = """
    WITH per_dump AS (
      SELECT
        d.id AS dump_id,
        d.status,
        d.inserted_at,
        COALESCE(cardinality(d.invoices), 0) AS invoice_count,
        MAX(a.source_page_count) AS page_count,
        MAX(a.source_byte_size) AS source_bytes,
        MIN(a.started_at) AS started_at,
        MAX(a.completed_at) AS completed_at,
        COUNT(*) AS provider_calls,
        SUM(a.duration_ms) FILTER (
          WHERE a.request_metadata->>'stage' = 'vision_segmentation'
        ) AS segmentation_ms,
        SUM(a.duration_ms) FILTER (
          WHERE a.request_metadata->>'stage' = 'vision_extraction'
        ) AS extraction_ms
      FROM gst_dumps d
      JOIN gst_extraction_attempts a ON a.gst_dump_id = d.id
      WHERE d.kind = 'sales' AND a.status = 'succeeded'
      GROUP BY d.id, d.status, d.inserted_at, d.invoices
    )
    SELECT
      dump_id,
      status,
      page_count,
      invoice_count,
      source_bytes,
      provider_calls,
      segmentation_ms,
      extraction_ms,
      ROUND(EXTRACT(EPOCH FROM (completed_at - started_at)) * 1000)::bigint AS wall_ms,
      inserted_at
    FROM per_dump
    WHERE completed_at IS NOT NULL
    ORDER BY inserted_at, dump_id
    """

    result = Nila.Repo.query!(sql)
    IO.puts(Enum.join(result.columns, ","))

    Enum.each(result.rows, fn row ->
      row
      |> Enum.map(&csv/1)
      |> Enum.join(",")
      |> IO.puts()
    end)
  end

  def run(["extract" | paths]) when paths != [] do
    start_extractor!()
    File.rm(@log_path)
    Enum.each(paths, &measure/1)
  end

  def run(_args) do
    IO.puts(:stderr, "usage: mix run eval/benchmarks/sales_extraction_curve.exs history")

    IO.puts(
      :stderr,
      "   or: mix run eval/benchmarks/sales_extraction_curve.exs extract PDF [PDF ...]"
    )

    System.halt(2)
  end

  defp measure(path) do
    bytes = File.read!(path)
    started = System.monotonic_time()

    per_call = fn metadata, call ->
      call_started = System.monotonic_time()
      result = call.()

      emit(%{
        event: "provider_call",
        file: path,
        metadata: metadata,
        duration_ms: elapsed_ms(call_started),
        outcome: outcome(result)
      })

      result
    end

    on_progress = fn progress ->
      emit(%{
        event: "progress",
        file: path,
        elapsed_ms: elapsed_ms(started),
        progress: normalize_progress(progress)
      })
    end

    result =
      Vision.extract(bytes,
        filename: path,
        per_call: per_call,
        on_progress: on_progress
      )

    summary =
      case result do
        {:ok, extracted} ->
          %{
            event: "complete",
            file: path,
            source_bytes: byte_size(bytes),
            duration_ms: elapsed_ms(started),
            invoice_count: length(extracted.pages),
            page_count: extracted.audit.source_page_count,
            unaccounted_pages: extracted.unaccounted_pages,
            outcome: "ok"
          }

        {:error, reason} ->
          %{
            event: "complete",
            file: path,
            source_bytes: byte_size(bytes),
            duration_ms: elapsed_ms(started),
            outcome: "error",
            error: inspect(reason)
          }
      end

    emit(summary)
  end

  defp start_repo! do
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _pid} = Nila.Repo.start_link()
  end

  defp start_extractor! do
    {:ok, _} = Application.ensure_all_started(:finch)

    case Process.whereis(OpenAICompatibleChatFinch) do
      nil ->
        {:ok, _pid} =
          Finch.start_link(
            name: OpenAICompatibleChatFinch,
            pools: %{
              OpenAICompatibleChatFinch.origin() => OpenAICompatibleChatFinch.pool_options()
            }
          )

      _pid ->
        :ok
    end
  end

  defp emit(value) do
    line = Jason.encode!(value)
    IO.puts(line)
    File.write!(@log_path, line <> "\n", [:append])
  end

  defp outcome({:ok, _result}), do: "ok"
  defp outcome({:error, _reason, _audit}), do: "error"
  defp outcome({:error, _reason}), do: "error"
  defp outcome(_result), do: "unknown"

  defp normalize_progress({kind, value}) when is_atom(kind),
    do: %{kind: kind, value: value}

  defp normalize_progress(value), do: inspect(value)

  defp elapsed_ms(started) do
    System.monotonic_time()
    |> Kernel.-(started)
    |> System.convert_time_unit(:native, :millisecond)
  end

  defp csv(nil), do: ""
  defp csv(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp csv(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp csv(value), do: to_string(value)
end

Nila.MeasureSalesExtractionCurve.run(System.argv())
