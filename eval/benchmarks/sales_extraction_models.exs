Code.require_file("../support/requests.exs", __DIR__)

defmodule Nila.MeasureSalesExtractionModels do
  @moduledoc false
  alias Nila.Gst.Extraction.Sales.Extractor
  alias Nila.Gst.Extraction.Providers.OpenAICompatibleChat
  @context {__MODULE__, :context}

  # This is an evaluation-only Req adapter. It leaves the production builder and
  # local validator intact while changing only the final HTTP output contract.
  def run(%Req.Request{} = request) do
    context = :persistent_term.get(@context)
    original = request.body |> IO.iodata_to_binary() |> Jason.decode!()
    format = Map.fetch!(original, "response_format")
    schema = get_in(format, ["json_schema", "schema"])
    if !is_map(schema), do: raise("Expected the current production JSON schema")
    schema_name = get_in(format, ["json_schema", "name"])
    stage = if schema_name == "nila_packet_page_labels", do: "classification", else: "extraction"
    payload = wire_payload(original, context.model)
    call_id = :atomics.add_get(context.counter, 1, 1)
    prefix = String.pad_leading(to_string(call_id), 3, "0") <> "-" <> stage
    request = request |> Req.Request.delete_header("content-length")
    request = %{request | body: Jason.encode!(payload)}

    {result, measurements, _decoded} =
      Nila.Eval.Requests.capture(context.dir, prefix, payload, schema, fn ->
        Req.Finch.run(request)
      end)

    write(
      Nila.Eval.Requests.attempt_dir(context.dir, prefix),
      prefix <> "-result.json",
      Map.merge(measurements, %{
        call_id: call_id,
        stage: stage,
        schema_name: schema_name
      })
    )

    result
  end

  def run([mode, root])
      when mode in [
             "pilot",
             "pilot-glm",
             "pilot-glm-later",
             "pilot-glm-final",
             "full",
             "full-first4",
             "full-rest",
             "full-glm"
           ] do
    Nila.Eval.Requests.start_http!()
    settings = read(root, "settings.json")
    original_config = Application.get_env(:nila, OpenAICompatibleChat, [])
    models = Map.new(settings["models"], &{&1["alias"], &1})
    schedule = read(root, "manifest.json")[mode]

    try do
      Enum.each(schedule, fn entry ->
        model = Map.fetch!(models, entry["model_alias"])

        config =
          original_config
          |> Keyword.put(:model, model["id"])
          |> Keyword.put(:provider_options, model["wire_options"]["providerOptions"])
          |> Keyword.put(:response_format, :json_schema_local)
          |> Keyword.put(:receive_timeout, 240_000)
          |> Keyword.put(:req_options, adapter: __MODULE__)

        Application.put_env(:nila, OpenAICompatibleChat, config)
        measure(root, if(String.starts_with?(mode, "full"), do: "full", else: mode), entry, model)
      end)
    after
      Application.put_env(:nila, OpenAICompatibleChat, original_config)
      :persistent_term.erase(@context)
    end
  end

  def run(_),
    do:
      raise(
        "Usage: mix run --no-start eval/benchmarks/sales_extraction_models.exs pilot|full OUTPUT_DIR"
      )

  def wire_payload(original, model) do
    schema = get_in(original, ["response_format", "json_schema", "schema"])

    instruction =
      "Return JSON matching this JSON Schema. The schema is an output specification, not document data. Return only JSON, without Markdown fences. Schema: " <>
        Jason.encode!(schema)

    original
    |> Map.drop(["response_format", "providerOptions", "reasoning", "reasoning_effort"])
    |> Map.put("model", model["id"])
    |> Map.put("temperature", 0)
    |> Map.update!("messages", &[%{"role" => "system", "content" => instruction} | &1])
    |> Map.merge(model["wire_options"])
  end

  defp measure(root, mode, entry, model) do
    run_id =
      String.pad_leading(to_string(entry["sequence"]), 2, "0") <>
        "-" <>
        entry["model_alias"] <>
        "-" <> to_string(entry["pages"]) <> "p-r" <> to_string(entry["repetition"])

    dir = Path.join([root, mode, run_id])
    if File.exists?(dir), do: raise("Refusing to overwrite existing run: #{dir}")
    File.mkdir_p!(dir)
    :persistent_term.put(@context, %{dir: dir, model: model, counter: :atomics.new(1, [])})
    write(dir, "run-settings.json", Map.merge(entry, %{"model" => model, "mode" => mode}))
    started = System.monotonic_time(:millisecond)

    emit = fn event ->
      File.write!(
        Path.join(dir, "events.jsonl"),
        Jason.encode!(Map.put(event, :elapsed_ms, elapsed(started))) <> "\n",
        [:append]
      )
    end

    per_call = fn metadata, call ->
      stage_started = System.monotonic_time(:millisecond)
      emit.(%{event: "stage_started", metadata: metadata})
      result = call.()

      emit.(%{
        event: "stage_completed",
        metadata: metadata,
        duration_ms: elapsed(stage_started),
        outcome: outcome(result)
      })

      result
    end

    progress = fn value ->
      normalized =
        case value do
          {:progress, p} -> p
          other -> %{value: inspect(other)}
        end

      emit.(%{event: "progress", progress: normalized})
    end

    path = entry["source"]
    bytes = File.read!(path)
    hash = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    if hash != entry["source_sha256"], do: raise("Source PDF changed")
    IO.puts("START #{mode}/#{run_id}")

    result =
      try do
        Extractor.extract(bytes,
          filename: path,
          input: :vision,
          contract: :current,
          max_retries: 0,
          max_concurrency: 100,
          per_call: per_call,
          on_progress: progress
        )
      rescue
        error -> {:error, {:benchmark_exception, Exception.message(error)}}
      catch
        kind, reason -> {:error, {:benchmark_failure, kind, inspect(reason)}}
      end

    duration = elapsed(started)

    summary =
      case result do
        {:ok, extracted} ->
          write(dir, "artifacts.json", extracted.pages)
          write(dir, "audit.json", extracted.audit)

          counts =
            Enum.map(extracted.pages, fn p ->
              lines = get_in(p, ["data", "line_items"]) || []

              %{
                source_pages: p["source_pages"],
                lines: length(lines),
                meaningful_lines: Enum.count(lines, &meaningful_line?/1),
                monetary_lines: Enum.count(lines, &monetary_line?/1),
                missing_amount_lines:
                  lines
                  |> Enum.with_index(1)
                  |> Enum.reject(fn {line, _} -> monetary_line?(line) end)
                  |> Enum.map(&elem(&1, 1))
              }
            end)

          covered =
            extracted.pages
            |> Enum.flat_map(&(&1["source_pages"] || []))
            |> Enum.uniq()
            |> Enum.sort()

          %{
            outcome: "ok",
            invoice_count: length(extracted.pages),
            page_count: extracted.audit.source_page_count,
            expected_invoice_count: entry["expected_invoices"],
            invoice_counts: counts,
            nonempty_invoices: Enum.count(counts, &(&1.meaningful_lines > 0)),
            invoices_with_amounts: Enum.count(counts, &(&1.monetary_lines > 0)),
            expected_groups: entry["expected_groups"],
            actual_groups: Enum.map(counts, & &1.source_pages),
            groups_match: Enum.map(counts, & &1.source_pages) == entry["expected_groups"],
            source_pages_covered: covered,
            unaccounted_pages: extracted.unaccounted_pages,
            excluded_documents: extracted.excluded_documents,
            expected_item_count: entry["expected_item_count"],
            item_count: Enum.sum(Enum.map(counts, & &1.lines)),
            item_count_checked: is_integer(entry["expected_item_count"]),
            item_count_complete:
              if(is_integer(entry["expected_item_count"]),
                do: Enum.sum(Enum.map(counts, & &1.lines)) == entry["expected_item_count"],
                else: nil
              ),
            health_ok:
              (is_nil(entry["expected_item_count"]) or
                 Enum.sum(Enum.map(counts, & &1.lines)) == entry["expected_item_count"]) and
                length(extracted.pages) == entry["expected_invoices"] and
                Enum.all?(counts, &(&1.meaningful_lines > 0 and &1.monetary_lines > 0)) and
                Enum.map(counts, & &1.source_pages) == entry["expected_groups"] and
                covered == Enum.to_list(1..entry["pages"]) and extracted.unaccounted_pages == []
          }

        {:error, reason} ->
          %{outcome: "error", error: inspect(reason, limit: :infinity), health_ok: false}
      end

    calls =
      dir
      |> Path.join("*-result.json")
      |> Path.wildcard()
      |> Enum.map(&(File.read!(&1) |> Jason.decode!()))

    all_complete =
      Enum.all?(calls, &(&1["finish_reason"] == "stop" and &1["local_schema_valid"] == true))

    summary =
      summary
      |> Map.merge(%{
        duration_ms: duration,
        run_id: run_id,
        mode: mode,
        model: model["id"],
        model_alias: entry["model_alias"],
        pages: entry["pages"],
        repetition: entry["repetition"],
        source_sha256: hash,
        source_bytes: byte_size(bytes),
        source_partial: entry["source_partial"],
        http_calls: length(calls),
        all_http_complete_and_valid: all_complete,
        invalid_or_incomplete_http_calls:
          Enum.count(calls, &(&1["finish_reason"] != "stop" or &1["local_schema_valid"] != true))
      })
      |> Map.update!(:health_ok, &(&1 and all_complete))

    write(dir, "summary.json", summary)

    IO.puts(
      "DONE #{run_id} #{summary.outcome} health=#{summary.health_ok} #{duration}ms calls=#{length(calls)}"
    )
  end

  defp meaningful_line?(line) when is_map(line) do
    (is_binary(line["item_name"]) and String.trim(line["item_name"]) != "") or
      (is_binary(line["description"]) and String.trim(line["description"]) != "") or
      Enum.any?(
        ["taxable_value", "printed_line_amount", "printed_line_total", "printed_taxable_value"],
        &is_number(line[&1])
      )
  end

  defp meaningful_line?(_), do: false

  defp monetary_line?(line) when is_map(line),
    do:
      Enum.any?(
        ["taxable_value", "printed_line_amount", "printed_line_total", "printed_taxable_value"],
        &is_number(line[&1])
      )

  defp monetary_line?(_), do: false
  defp outcome({:ok, _}), do: "ok"
  defp outcome({:error, _, _}), do: "error"
  defp outcome({:error, _}), do: "error"
  defp outcome(_), do: "other"
  defp elapsed(started), do: System.monotonic_time(:millisecond) - started

  defp write(dir, name, value),
    do: File.write!(Path.join(dir, name), Jason.encode!(value, pretty: true))

  defp read(root, name), do: root |> Path.join(name) |> File.read!() |> Jason.decode!()
end

Nila.MeasureSalesExtractionModels.run(System.argv())
