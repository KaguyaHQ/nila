defmodule Nila.Eval.Segmented do
  @moduledoc """
  Runs the segmented pipeline over a corpus document and caches what each call
  returned.

  Only response bytes are cached at the network boundary, and every pure step
  downstream runs at score time. So
  tightening a guard, the stitcher or a verifier re-scores the whole corpus for
  free, and no number can be attributed to code that no longer runs.

  Three stages, three caches, because the whole point of splitting them is that
  they fail differently and must be measured apart:

      transcription/  one pure-OCR read of the document      (Nila.Eval.Transcription)
      discovery/      one label per page, or one whole dump  (re-stitched at score time)
      raw/            one call per invoice segment           (re-verified at score time)

  Discovery and extraction are cached separately for a reason that bit the first
  version of this module: a segment is defined *before* its invoice is extracted,
  so replay cannot re-cut segments — the cached extraction call was made against
  those pages and no other. Each cached chunk therefore carries the segment it
  was called with, while `replay_discovery/1` re-runs the stitcher and guards
  over the cached labels independently. A bad boundary and a bad read are never
  the same number.
  """

  alias Nila.Eval.Transcription, as: EvalTranscription
  alias Nila.EvalCorpus
  alias Nila.Gst.Extraction.Discovery
  alias Nila.Gst.Extraction.Discovery.PageLabels
  alias Nila.Gst.Extraction.Providers.OpenAICompatibleChat
  alias Nila.Gst.Extraction.Segmented
  alias Nila.Gst.Extraction.Transcription

  @root "tmp/eval/segmented"
  @stability_root "tmp/eval/stability"
  @stability_fields ~w(invoice_number line_count buyer_gstin seller_gstin printed_total_taxable printed_total_tax printed_grand_total line_items verification_status verification_flags repairs artifact_sha256)

  @doc """
  Transcribe (cached) → discover → extract per segment. Writes a new attempt.

  `:shape` picks the decider (`:per_page`, the default, or `:whole_dump`).
  `:on_event` receives `{:transcribed, pages}`, `{:segmented, segments,
  violations}` and `{:segment, done, total}`.
  """
  def run(name, opts \\ []) do
    doc = EvalCorpus.document!(name)
    kind = kind!(doc)
    shape = Keyword.get(opts, :shape, :per_page)
    context = Keyword.get(opts, :context, :paper)
    report = Keyword.get(opts, :on_event, fn _event -> :ok end)
    started = System.monotonic_time(:millisecond)

    with {:ok, transcription_dir} <- EvalTranscription.ensure(name),
         {:ok, transcription} <- EvalTranscription.load(transcription_dir),
         :ok <- report.({:transcribed, Transcription.page_count(transcription)}),
         {:ok, responses} <- discover(shape, transcription, Keyword.put(opts, :kind, kind)),
         {:ok, discovery} <- interpret(shape, transcription, responses, kind) do
      report.({:segmented, discovery.segments, discovery.violations})
      client_gstin = Discovery.client_gstin(transcription)

      dir =
        Path.join([
          @root,
          extract_id(doc, kind, shape, transcription_dir, context),
          attempt_id()
        ])

      File.mkdir_p!(Path.join(dir, "raw"))
      write_discovery!(dir, shape, responses, discovery)

      invoice_segments = Enum.filter(discovery.segments, &(&1.kind == :invoice))

      case capture_segments(kind, transcription, invoice_segments, dir, report, opts) do
        {:ok, _calls} ->
          write_meta!(
            dir,
            doc,
            kind,
            shape,
            context,
            transcription_dir,
            transcription,
            discovery,
            client_gstin,
            started
          )

          {:ok, dir}

        {:error, reason, _calls} ->
          File.rm_rf(dir)
          {:error, reason}
      end
    end
  end

  @doc "Runs repeated extraction against one transcription and one fixed segment set."
  def stability(name, opts \\ []) do
    doc = EvalCorpus.document!(name)
    kind = kind!(doc)
    shape = Keyword.get(opts, :shape, :per_page)
    context = Keyword.get(opts, :context, :paper)
    runs = Keyword.get(opts, :runs, 10)
    concurrency = Keyword.get(opts, :max_concurrency, 4)
    report = Keyword.get(opts, :on_event, fn _event -> :ok end)

    with {:ok, transcription_dir} <- EvalTranscription.ensure(name),
         {:ok, transcription} <- EvalTranscription.load(transcription_dir),
         :ok <- report.({:transcribed, Transcription.page_count(transcription)}),
         {:ok, responses} <- discover(shape, transcription, Keyword.put(opts, :kind, kind)),
         {:ok, discovery} <- interpret(shape, transcription, responses, kind) do
      report.({:segmented, discovery.segments, discovery.violations})

      batch_id = stability_batch_id()
      batch_dir = Path.join([@stability_root, doc["name"], batch_id])
      client_gstin = Discovery.client_gstin(transcription)
      invoice_segments = Enum.filter(discovery.segments, &(&1.kind == :invoice))
      capture_opts = Keyword.put(opts, :max_concurrency, concurrency)

      File.mkdir_p!(batch_dir)
      write_discovery!(batch_dir, shape, responses, discovery)

      {completed, failures} =
        Enum.reduce(1..runs, {[], []}, fn index, {completed, failures} ->
          run_started = System.monotonic_time(:millisecond)
          run_dir = Path.join([batch_dir, "runs", "run_#{pad(index)}"])
          File.mkdir_p!(Path.join(run_dir, "raw"))
          write_segments!(run_dir, discovery)

          capture =
            capture_segments(
              kind,
              transcription,
              invoice_segments,
              run_dir,
              fn _event -> :ok end,
              capture_opts
            )

          case capture do
            {:ok, calls} ->
              write_meta!(
                run_dir,
                doc,
                kind,
                shape,
                context,
                transcription_dir,
                transcription,
                discovery,
                client_gstin,
                run_started
              )

              put_stability_meta!(run_dir, batch_id, index, concurrency)

              case replay(run_dir) do
                {:ok, assembled} ->
                  run = stability_run(index, run_dir, calls, assembled)
                  report.({:stability_run, index, runs, run})
                  {[run | completed], failures}

                {:error, reason} ->
                  failure = stability_failure(index, run_dir, {:replay_failed, reason})
                  write_json!(Path.join(run_dir, "failure.json"), failure)
                  report.({:stability_failure, index, runs, failure})
                  {completed, [failure | failures]}
              end

            {:error, reason, calls} ->
              failure = stability_failure(index, run_dir, {:extraction_failed, reason}, calls)
              write_json!(Path.join(run_dir, "failure.json"), failure)
              report.({:stability_failure, index, runs, failure})
              {completed, [failure | failures]}
          end
        end)

      stability_report =
        completed
        |> Enum.reverse()
        |> build_stability_report(
          Enum.reverse(failures),
          runs,
          doc,
          kind,
          shape,
          context,
          concurrency,
          transcription_dir,
          discovery,
          batch_dir
        )

      write_json!(Path.join(batch_dir, "report.json"), stability_report)
      {:ok, stability_report}
    end
  end

  # ---- discovery ----

  defp discover(:per_page, transcription, opts), do: PageLabels.request_all(transcription, opts)

  defp discover(:whole_dump, transcription, opts) do
    with {:ok, response} <- Discovery.request_raw(transcription, opts), do: {:ok, response}
  end

  # Both shapes end at the same guards, so a rule can never apply to one decider
  # and not the other.
  defp interpret(:per_page, transcription, responses, kind) do
    with {:ok, labels} <- PageLabels.map_responses(responses) do
      {segments, violations} =
        Discovery.guard(transcription, PageLabels.stitch(labels), kind: kind)

      {:ok, %{segments: segments, violations: violations, labels: labels}}
    end
  end

  defp interpret(:whole_dump, transcription, response, kind) do
    with {:ok, result} <- Discovery.map_response(transcription, response, kind: kind) do
      {:ok, Map.put(result, :labels, [])}
    end
  end

  defp write_discovery!(dir, shape, responses, discovery) do
    File.mkdir_p!(Path.join(dir, "discovery"))

    case shape do
      :per_page ->
        Enum.each(responses, fn entry ->
          name = "page_#{pad(entry.page)}"

          case entry do
            %{response: response} ->
              File.write!(Path.join([dir, "discovery", "#{name}.json"]), response.body)

              File.write!(
                Path.join([dir, "discovery", "#{name}.meta.json"]),
                Jason.encode!(%{
                  "page" => entry.page,
                  "status" => response.status,
                  "response_format" =>
                    to_string(response.response_format || OpenAICompatibleChat.response_format())
                })
              )

            %{error: reason} ->
              File.write!(
                Path.join([dir, "discovery", "#{name}.meta.json"]),
                Jason.encode!(%{"page" => entry.page, "error" => inspect(reason)})
              )
          end
        end)

      :whole_dump ->
        File.write!(Path.join([dir, "discovery", "dump.json"]), responses.body)

        File.write!(
          Path.join([dir, "discovery", "dump.meta.json"]),
          Jason.encode!(%{
            "status" => responses.status,
            "response_format" =>
              to_string(responses.response_format || OpenAICompatibleChat.response_format())
          })
        )
    end

    write_segments!(dir, discovery)
  end

  defp write_segments!(dir, discovery) do
    File.write!(
      Path.join(dir, "segments.json"),
      Jason.encode!(
        %{
          "segments" => Enum.map(discovery.segments, &encode_segment/1),
          "violations" => Enum.map(discovery.violations, &Discovery.describe/1)
        },
        pretty: true
      )
    )
  end

  @doc "Re-runs the stitcher and guards over the cached decider responses."
  def replay_discovery(dir) do
    meta = read_json!(Path.join(dir, "meta.json"))
    shape = String.to_existing_atom(meta["discovery_shape"])

    with {:ok, transcription} <- EvalTranscription.load(meta["transcription_attempt"]) do
      kind = String.to_existing_atom(meta["kind"])
      interpret(shape, transcription, cached_discovery(dir, shape), kind)
    end
  end

  defp cached_discovery(dir, :per_page) do
    dir
    |> Path.join("discovery/page_*.meta.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(fn meta_path ->
      meta = read_json!(meta_path)
      body = meta_path |> String.replace_suffix(".meta.json", ".json") |> File.read!()

      %{
        page: meta["page"],
        response: %{
          status: meta["status"] || 200,
          headers: %{},
          body: body,
          response_format: response_format(meta)
        }
      }
    end)
  end

  defp cached_discovery(dir, :whole_dump) do
    meta_path = Path.join(dir, "discovery/dump.meta.json")
    meta = if File.exists?(meta_path), do: read_json!(meta_path), else: %{}

    %{
      status: meta["status"] || 200,
      headers: %{},
      body: File.read!(Path.join(dir, "discovery/dump.json")),
      response_format: response_format(meta)
    }
  end

  # ---- extraction ----

  defp capture_segments(kind, transcription, segments, dir, report, opts) do
    total = length(segments)

    {_done, calls, errors} =
      segments
      |> Enum.with_index(1)
      |> Task.async_stream(
        fn {segment, index} ->
          {duration_us, result} =
            :timer.tc(fn -> Segmented.request_segment(kind, transcription, segment, opts) end)

          {index, segment, div(duration_us, 1_000), result}
        end,
        max_concurrency: Keyword.get(opts, :max_concurrency, 4),
        ordered: false,
        timeout: :infinity
      )
      |> Enum.reduce({0, [], []}, fn
        {:ok, {index, segment, duration_ms, {:ok, responses}}}, {done, calls, errors} ->
          call = segment_call(segment, duration_ms, responses)
          write_segment!(dir, index, segment, duration_ms, responses)
          report.({:segment, done + 1, total})
          {done + 1, [call | calls], errors}

        {:ok, {index, segment, duration_ms, {:error, reason, responses}}},
        {done, calls, errors} ->
          call =
            segment_call(segment, duration_ms, responses) |> Map.put("error", inspect(reason))

          write_segment!(dir, index, segment, duration_ms, responses)
          report.({:segment, done + 1, total})

          {done + 1, [call | calls],
           [%{"pages" => segment.pages, "reason" => inspect(reason)} | errors]}

        {:exit, reason}, {done, calls, errors} ->
          report.({:segment, done + 1, total})
          {done + 1, calls, [%{"pages" => [], "reason" => inspect(reason)} | errors]}
      end)

    calls = Enum.sort_by(calls, &List.first(&1["pages"]))

    case Enum.reverse(errors) do
      [] -> {:ok, calls}
      errors -> {:error, {:segments_failed, errors}, calls}
    end
  end

  defp write_segment!(dir, index, segment, duration_ms, responses) do
    responses
    |> Enum.with_index()
    |> Enum.each(fn {%{pages: pages, response: response}, chunk} ->
      name = "seg_#{pad(index)}_chunk_#{chunk}"
      File.write!(Path.join([dir, "raw", "#{name}.json"]), response.body)

      File.write!(
        Path.join([dir, "raw", "#{name}.meta.json"]),
        Jason.encode!(%{
          "segment_index" => index,
          "chunk" => chunk,
          "chunk_pages" => pages,
          "status" => response.status,
          "segment_duration_ms" => duration_ms,
          "provider_request_id" => provider_request_id(response.headers),
          "usage" => response_usage(response),
          "response_sha256" => sha256(response.body),
          "response_format" =>
            to_string(response.response_format || OpenAICompatibleChat.response_format()),
          "segment" => encode_segment(segment)
        })
      )
    end)
  end

  defp segment_call(segment, duration_ms, responses) do
    usage = responses |> Enum.map(&response_usage(&1.response)) |> Segmented.sum_usage()

    %{
      "invoice" => segment.invoice_no,
      "pages" => segment.pages,
      "duration_ms" => duration_ms,
      "statuses" => Enum.map(responses, & &1.response.status),
      "usage" => usage,
      "output_tokens" => usage["completion_tokens"],
      "provider_request_ids" =>
        responses |> Enum.map(&provider_request_id(&1.response.headers)) |> Enum.reject(&is_nil/1),
      "response_sha256" => sha256(Enum.map(responses, & &1.response.body))
    }
  end

  defp stability_failure(index, work_dir, reason, calls \\ []) do
    %{
      "run" => index,
      "status" => "failed",
      "attempt" => work_dir,
      "reason" => inspect(reason, limit: 20, printable_limit: 2_000),
      "calls" => calls
    }
  end

  defp stability_run(index, run_dir, calls, assembled) do
    invoices = Enum.map(assembled.pages, &stability_invoice/1)
    meta = read_json!(Path.join(run_dir, "meta.json"))

    %{
      "run" => index,
      "attempt" => run_dir,
      "duration_ms" => meta["duration_ms"],
      "calls" => calls,
      "output_sha256" => invoices |> Jason.encode!() |> sha256(),
      "invoices" => invoices
    }
  end

  defp stability_invoice(artifact) do
    data = artifact["data"] || %{}
    verification = artifact["verification"] || %{}
    semantic_artifact = Map.take(artifact, ["data", "verification", "repairs", "document"])

    %{
      "segment_key" => Enum.join(artifact["source_pages"], ","),
      "invoice_number" => data["invoice_number"],
      "pages" => artifact["source_pages"],
      "line_count" => length(data["line_items"] || []),
      "buyer_gstin" => get_in(data, ["buyer", "gstin"]),
      "seller_gstin" => get_in(data, ["seller", "gstin"]),
      "printed_total_taxable" => data["printed_total_taxable"],
      "printed_total_tax" => data["printed_total_tax"],
      "printed_grand_total" => data["printed_grand_total"],
      "line_items" => data["line_items"] || [],
      "verification_status" => verification["status"],
      "verification_flags" => verification["flags"] || [],
      "repairs" => artifact["repairs"] || [],
      "artifact_sha256" => semantic_artifact |> Jason.encode!() |> sha256()
    }
  end

  defp build_stability_report(
         runs,
         failures,
         requested_runs,
         doc,
         kind,
         shape,
         context,
         concurrency,
         transcription_dir,
         discovery,
         batch_dir
       ) do
    summary = summarize_stability(runs)

    Map.merge(summary, %{
      "document" => doc["name"],
      "provider" => OpenAICompatibleChat.provider(),
      "model" => OpenAICompatibleChat.model(),
      "discovery_shape" => to_string(shape),
      "discovery_context" => to_string(context),
      "concurrency" => concurrency,
      "requested_runs" => requested_runs,
      "successful_runs" => length(runs),
      "failed_runs" => length(failures),
      "failures" => failures,
      "transcription_attempt" => transcription_dir,
      "extraction_fingerprint" =>
        OpenAICompatibleChat.fingerprint(Segmented.prompt(kind), Segmented.schema(kind)),
      "discovery_fingerprint" => discovery_fingerprint(shape, kind, context),
      "fixed_segments_sha256" => discovery.segments |> encode_segments() |> sha256(),
      "dir" => batch_dir,
      "runs_detail" => runs,
      "created_at" => stamp()
    })
  end

  @doc false
  def summarize_stability([]) do
    %{
      "runs" => 0,
      "identical_outputs" => false,
      "unique_output_sets" => 0,
      "output_frequencies" => %{},
      "latency_ms" => %{"batch" => nil, "call" => nil},
      "invoices" => []
    }
  end

  def summarize_stability(runs) when is_list(runs) do
    calls = Enum.flat_map(runs, & &1["calls"])
    batch_durations = Enum.map(runs, & &1["duration_ms"])
    call_durations = Enum.map(calls, & &1["duration_ms"])
    output_hashes = runs |> Enum.map(& &1["output_sha256"]) |> Enum.frequencies()

    segment_keys =
      runs
      |> Enum.flat_map(& &1["invoices"])
      |> Enum.map(& &1["segment_key"])
      |> Enum.uniq()
      |> Enum.sort()

    %{
      "runs" => length(runs),
      "identical_outputs" => map_size(output_hashes) == 1,
      "unique_output_sets" => map_size(output_hashes),
      "output_frequencies" => output_hashes,
      "latency_ms" => %{
        "batch" => latency_summary(batch_durations),
        "call" => latency_summary(call_durations)
      },
      "invoices" => Enum.map(segment_keys, &invoice_stability(&1, runs))
    }
  end

  defp invoice_stability(segment_key, runs) do
    snapshots =
      Enum.map(runs, fn run ->
        Enum.find(run["invoices"], &(&1["segment_key"] == segment_key))
      end)

    variants =
      Map.new(@stability_fields, fn field ->
        {field, snapshots |> Enum.map(&(&1 && &1[field])) |> Enum.uniq()}
      end)

    stable =
      if length(runs) > 1,
        do: Enum.all?(variants, fn {_field, values} -> length(values) == 1 end),
        else: nil

    %{
      "segment_key" => segment_key,
      "stable" => stable,
      "missing_runs" => Enum.count(snapshots, &is_nil/1),
      "variants" => variants
    }
  end

  defp latency_summary([]), do: nil

  defp latency_summary(values) do
    %{
      "min" => Enum.min(values),
      "p50" => percentile(values, 0.50),
      "p95" => percentile(values, 0.95),
      "max" => Enum.max(values)
    }
  end

  defp percentile(values, fraction) do
    sorted = Enum.sort(values)
    rank = max(ceil(length(sorted) * fraction), 1)
    Enum.at(sorted, rank - 1)
  end

  defp put_stability_meta!(run_dir, batch_id, index, concurrency) do
    path = Path.join(run_dir, "meta.json")

    path
    |> read_json!()
    |> Map.merge(%{
      "stability_batch" => batch_id,
      "stability_run" => index,
      "stability_concurrency" => concurrency,
      "fixed_discovery" => true
    })
    |> then(&write_json!(path, &1))
  end

  defp response_usage(response) do
    case Jason.decode(response.body) do
      {:ok, %{"usage" => usage}} when is_map(usage) -> usage
      _missing -> %{}
    end
  end

  defp provider_request_id(headers) do
    Enum.find_value(
      ["x-request-id", "x-ai-gateway-request-id", "x-vercel-id"],
      &first_header(headers, &1)
    )
  end

  defp first_header(headers, name) do
    case Map.get(headers, name, []) do
      [value | _rest] -> value
      value when is_binary(value) -> value
      _missing -> nil
    end
  end

  defp sha256(value) do
    value
    |> IO.iodata_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp write_json!(path, value), do: File.write!(path, Jason.encode!(value, pretty: true))

  @doc """
  Replays a cached attempt into the assembled shape `Nila.Eval` scores.

  Verification runs now, so a sharper grounding rule shows up in the next score
  with no API call.
  """
  def replay(dir) do
    meta = read_json!(Path.join(dir, "meta.json"))
    kind = String.to_existing_atom(meta["kind"])

    with {:ok, transcription} <- EvalTranscription.load(meta["transcription_attempt"]) do
      results =
        dir
        |> Path.join("raw/*.meta.json")
        |> Path.wildcard()
        |> Enum.sort()
        |> Enum.map(&load_chunk/1)
        |> Enum.group_by(& &1.segment_index)
        |> Enum.sort_by(fn {index, _chunks} -> index end)
        |> Enum.map(fn {_index, chunks} ->
          chunks = Enum.sort_by(chunks, & &1.chunk)
          segment = chunks |> List.first() |> Map.fetch!(:segment)
          responses = Enum.map(chunks, &%{pages: &1.chunk_pages, response: &1.response})

          Segmented.map_segment(kind, transcription, segment, responses,
            client_gstin: meta["client_gstin"] || meta["buyer_gstin"]
          )
        end)

      failures = Enum.flat_map(results, &replay_failure/1)

      if failures == [] do
        artifacts =
          results
          |> Enum.map(fn {:ok, artifact} -> artifact end)
          |> Enum.sort_by(& &1["page"])

        {:ok,
         %{
           pages: artifacts,
           images: %{},
           audit: %{
             provider: meta["provider"],
             model: meta["model"],
             discovery_shape: meta["discovery_shape"],
             failures: []
           },
           unaccounted_pages: unaccounted(meta, artifacts)
         }}
      else
        {:error, {:invoice_segments_failed, failures}}
      end
    end
  end

  defp replay_failure({:error, reason}), do: [inspect(reason)]
  defp replay_failure(_ok), do: []

  # Only a *confirmed* non-invoice accounts for its page. A page the decider
  # called non-invoice without evidence is `:unreadable` by then, and lands here
  # as unaccounted — the ledger says so rather than the packet quietly shrinking.
  defp unaccounted(meta, artifacts) do
    claimed = artifacts |> Enum.flat_map(& &1["source_pages"]) |> MapSet.new()
    accounted = MapSet.new(meta["non_invoice_pages"] || [])

    1..(meta["page_count"] || 0)//1
    |> Enum.reject(&(MapSet.member?(claimed, &1) or MapSet.member?(accounted, &1)))
  end

  @doc "The newest attempt for a corpus document."
  def latest_attempt(name, opts \\ []) do
    doc = EvalCorpus.document!(name)
    shape = Keyword.get(opts, :shape, :per_page)
    context = Keyword.get(opts, :context, :paper)

    with {:ok, transcription_dir} <- EvalTranscription.latest_attempt(name) do
      id = extract_id(doc, kind!(doc), shape, transcription_dir, context)

      case @root |> Path.join("#{id}/*") |> Path.wildcard() |> Enum.sort() |> List.last() do
        nil -> {:error, {:no_attempt, name}}
        dir -> {:ok, dir}
      end
    end
  end

  @doc """
  The cache key: the document, the transcription it was read from, the decider
  shape, and both model/prompt/schema pairs that interpret it.
  """
  def extract_id(doc, kind, shape, transcription_dir, context \\ :paper) do
    discovery = discovery_fingerprint(shape, kind, context)
    extraction = OpenAICompatibleChat.fingerprint(Segmented.prompt(kind), Segmented.schema(kind))

    :crypto.hash(
      :sha256,
      Enum.join(
        [
          doc["sha256"],
          Path.basename(Path.dirname(transcription_dir)),
          "segmented",
          to_string(shape),
          discovery.provider,
          discovery.base_url,
          discovery.model,
          discovery.response_format,
          discovery.prompt_version,
          discovery.provider_options,
          discovery.context_strategy,
          discovery.prompt,
          discovery.schema,
          extraction.provider,
          extraction.base_url,
          extraction.model,
          extraction.response_format,
          extraction.prompt_version,
          extraction.provider_options,
          extraction.prompt,
          extraction.schema
        ],
        "|"
      )
    )
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  defp discovery_fingerprint(:per_page, kind, context) do
    PageLabels.prompt(kind)
    |> OpenAICompatibleChat.fingerprint(PageLabels.schema())
    |> Map.put(:context_strategy, PageLabels.context_fingerprint(context))
  end

  defp discovery_fingerprint(:whole_dump, _kind, _context) do
    Discovery.prompt()
    |> OpenAICompatibleChat.fingerprint(Discovery.schema())
    |> Map.put(:context_strategy, "whole-dump-v1")
  end

  defp load_chunk(meta_path) do
    meta = read_json!(meta_path)
    body = meta_path |> String.replace_suffix(".meta.json", ".json") |> File.read!()

    %{
      segment_index: meta["segment_index"],
      chunk: meta["chunk"],
      chunk_pages: meta["chunk_pages"],
      segment: decode_segment(meta["segment"]),
      response: %{
        status: meta["status"] || 200,
        headers: %{},
        body: body,
        response_format: response_format(meta)
      }
    }
  end

  defp encode_segments(segments), do: segments |> Enum.map(&encode_segment/1) |> Jason.encode!()

  defp encode_segment(segment) do
    %{
      "pages" => segment.pages,
      "kind" => to_string(segment.kind),
      "invoice_no" => segment.invoice_no,
      "reason" => segment.reason,
      "issues" => Enum.map(segment.issues, &inspect(&1, charlists: :as_lists))
    }
  end

  defp decode_segment(encoded) do
    %{
      pages: encoded["pages"],
      kind: String.to_existing_atom(encoded["kind"]),
      invoice_no: encoded["invoice_no"],
      reason: encoded["reason"],
      issues: encoded["issues"] || []
    }
  end

  defp write_meta!(
         dir,
         doc,
         kind,
         shape,
         context,
         transcription_dir,
         transcription,
         discovery,
         client_gstin,
         started
       ) do
    confirmed_non_invoice =
      discovery.segments |> Enum.filter(&(&1.kind == :non_invoice)) |> Enum.flat_map(& &1.pages)

    File.write!(
      Path.join(dir, "meta.json"),
      Jason.encode!(
        %{
          "document" => doc["name"],
          "kind" => to_string(kind),
          "pipeline" => "segmented",
          "discovery_shape" => to_string(shape),
          "discovery_context" => to_string(context),
          "provider" => OpenAICompatibleChat.provider(),
          "model" => OpenAICompatibleChat.model(),
          "fingerprint" =>
            OpenAICompatibleChat.fingerprint(Segmented.prompt(kind), Segmented.schema(kind)),
          "discovery_fingerprint" => discovery_fingerprint(shape, kind, context),
          "transcription_attempt" => transcription_dir,
          "client_gstin" => client_gstin,
          "page_count" => Transcription.page_count(transcription),
          "segments" => length(discovery.segments),
          "invoice_segments" => Enum.count(discovery.segments, &(&1.kind == :invoice)),
          "non_invoice_pages" => Enum.sort(confirmed_non_invoice),
          "violations" => Enum.map(discovery.violations, &Discovery.describe/1),
          "duration_ms" => System.monotonic_time(:millisecond) - started,
          "extracted_at" => stamp()
        },
        pretty: true
      )
    )
  end

  defp response_format(meta) do
    case meta["response_format"] do
      "json_object" -> :json_object
      "json_schema_local" -> :json_schema_local
      _strict_or_legacy -> :json_schema
    end
  end

  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()

  defp pad(number), do: number |> to_string() |> String.pad_leading(3, "0")

  defp kind!(%{"kind" => "sales"}), do: :sales
  defp kind!(%{"kind" => "purchase"}), do: :purchase

  defp kind!(doc),
    do: raise(ArgumentError, "corpus document #{doc["name"]} has no extractable kind")

  defp attempt_id, do: String.replace(stamp(), ":", "-")

  defp stability_batch_id do
    suffix =
      System.unique_integer([:positive, :monotonic]) |> to_string() |> String.pad_leading(10, "0")

    "#{attempt_id()}-#{suffix}"
  end

  defp stamp, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
