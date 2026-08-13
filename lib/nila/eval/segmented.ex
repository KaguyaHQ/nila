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
  alias Nila.Gst.Extraction.Providers.MistralChat
  alias Nila.Gst.Extraction.Segmented
  alias Nila.Gst.Extraction.Transcription

  @root "tmp/eval/segmented"

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
    report = Keyword.get(opts, :on_event, fn _event -> :ok end)
    started = System.monotonic_time(:millisecond)

    with {:ok, transcription_dir} <- EvalTranscription.ensure(name),
         {:ok, transcription} <- EvalTranscription.load(transcription_dir),
         :ok <- report.({:transcribed, Transcription.page_count(transcription)}),
         {:ok, responses} <- discover(shape, transcription, Keyword.put(opts, :kind, kind)),
         {:ok, discovery} <- interpret(shape, transcription, responses, kind) do
      report.({:segmented, discovery.segments, discovery.violations})
      client_gstin = Discovery.client_gstin(transcription)

      dir = Path.join([@root, extract_id(doc, kind, shape, transcription_dir), attempt_id()])
      File.mkdir_p!(Path.join(dir, "raw"))
      write_discovery!(dir, shape, responses, discovery)

      invoice_segments = Enum.filter(discovery.segments, &(&1.kind == :invoice))

      case capture_segments(kind, transcription, invoice_segments, dir, report, opts) do
        :ok ->
          write_meta!(
            dir,
            doc,
            kind,
            shape,
            transcription_dir,
            transcription,
            discovery,
            client_gstin,
            started
          )

          {:ok, dir}

        {:error, reason} ->
          File.rm_rf(dir)
          {:error, reason}
      end
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
                Jason.encode!(%{"page" => entry.page, "status" => response.status})
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
    end

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
      %{page: meta["page"], response: %{status: meta["status"] || 200, headers: %{}, body: body}}
    end)
  end

  defp cached_discovery(dir, :whole_dump) do
    %{status: 200, headers: %{}, body: File.read!(Path.join(dir, "discovery/dump.json"))}
  end

  # ---- extraction ----

  defp capture_segments(kind, transcription, segments, dir, report, opts) do
    total = length(segments)

    segments
    |> Enum.with_index(1)
    |> Task.async_stream(
      fn {segment, index} ->
        {index, segment, Segmented.request_segment(kind, transcription, segment, opts)}
      end,
      max_concurrency: Keyword.get(opts, :max_concurrency, 4),
      timeout: :infinity
    )
    |> Enum.reduce_while({:ok, 0}, fn {:ok, {index, segment, result}}, {:ok, done} ->
      case result do
        {:ok, responses} ->
          write_segment!(dir, index, segment, responses)
          report.({:segment, done + 1, total})
          {:cont, {:ok, done + 1}}

        {:error, reason} ->
          {:halt, {:error, {:segment_failed, segment.pages, reason}}}
      end
    end)
    |> case do
      {:ok, _done} -> :ok
      error -> error
    end
  end

  defp write_segment!(dir, index, segment, responses) do
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
          "segment" => encode_segment(segment)
        })
      )
    end)
  end

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

    with {:ok, transcription_dir} <- EvalTranscription.latest_attempt(name) do
      id = extract_id(doc, kind!(doc), shape, transcription_dir)

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
  def extract_id(doc, kind, shape, transcription_dir) do
    discovery = discovery_fingerprint(shape)
    extraction = MistralChat.fingerprint(Segmented.prompt(kind), Segmented.schema(kind))

    :crypto.hash(
      :sha256,
      Enum.join(
        [
          doc["sha256"],
          Path.basename(Path.dirname(transcription_dir)),
          "segmented",
          to_string(shape),
          discovery.model,
          discovery.prompt,
          discovery.schema,
          extraction.model,
          extraction.prompt,
          extraction.schema
        ],
        "|"
      )
    )
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  defp discovery_fingerprint(:per_page),
    do: MistralChat.fingerprint(PageLabels.prompt(), PageLabels.schema())

  defp discovery_fingerprint(:whole_dump),
    do: MistralChat.fingerprint(Discovery.prompt(), Discovery.schema())

  defp load_chunk(meta_path) do
    meta = read_json!(meta_path)
    body = meta_path |> String.replace_suffix(".meta.json", ".json") |> File.read!()

    %{
      segment_index: meta["segment_index"],
      chunk: meta["chunk"],
      chunk_pages: meta["chunk_pages"],
      segment: decode_segment(meta["segment"]),
      response: %{status: meta["status"] || 200, headers: %{}, body: body}
    }
  end

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
          "provider" => MistralChat.provider(),
          "model" => MistralChat.model(),
          "fingerprint" =>
            MistralChat.fingerprint(Segmented.prompt(kind), Segmented.schema(kind)),
          "discovery_fingerprint" => discovery_fingerprint(shape),
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

  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()

  defp pad(number), do: number |> to_string() |> String.pad_leading(3, "0")

  defp kind!(%{"kind" => "sales"}), do: :sales
  defp kind!(%{"kind" => "purchase"}), do: :purchase

  defp kind!(doc),
    do: raise(ArgumentError, "corpus document #{doc["name"]} has no extractable kind")

  defp attempt_id, do: String.replace(stamp(), ":", "-")

  defp stamp, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
