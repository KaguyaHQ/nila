defmodule Nila.Eval.Extraction do
  @moduledoc """
  Runs the production extractor over a corpus document and caches what the
  provider sent back.

  ## What is cached, and what is not

  Only the raw HTTP response bodies and the page numbers each window asked for.
  Everything downstream — `Mistral.map_response/3`, `Windowed.assemble/2`,
  `Gstr1.normalize_invoice/1` — is recomputed on every score.

  This is the whole point. `assemble/2` decides which of two overlapping reads
  of an invoice survives, and `map_response/3` decides which pages an artifact
  claims; both are pure, both change when their rules are edited, and caching
  either would hand back a number attributed to code that no longer runs.
  Caching strictly at the network boundary means no pure edit can ever be masked
  by a cache hit, and re-scoring the whole corpus after a rule change costs zero
  API calls.

  ## Attempts are never overwritten

  The model is non-deterministic, so `extract_id` names a *configuration*, not a
  result: two runs with the same id return different invoices. Each run
  therefore writes a new timestamped attempt, and a run record names the exact
  attempt it scored. Overwriting would silently rewrite history, which is the
  failure this loop exists to remove.
  """

  alias Nila.EvalCorpus
  alias Nila.Gst.Extraction.Providers.Mistral
  alias Nila.Gst.Extraction.Windowed

  @root "tmp/eval/extractions"

  @doc """
  Extracts a corpus document window by window, writing a new attempt.

  Returns `{:ok, attempt_dir}`. Provider failures abort: a partially extracted
  month scored as if whole is worse than no month.
  """
  def run(name, opts \\ []) do
    doc = EvalCorpus.document!(name)
    path = EvalCorpus.fetch!(name)
    bytes = File.read!(path)
    kind = kind!(doc)

    extract_id = extract_id(doc, kind)
    dir = Path.join([@root, extract_id, attempt_id()])
    File.mkdir_p!(Path.join(dir, "raw"))

    started = System.monotonic_time(:millisecond)
    windows = plan(bytes, opts)

    report = Keyword.get(opts, :on_window, fn _event -> :ok end)
    report.({:plan, length(windows)})

    case capture_windows(kind, bytes, windows, dir, report) do
      {:ok, captured} ->
        write_meta!(dir, doc, kind, extract_id, captured, started, bytes)
        {:ok, dir}

      {:error, reason} ->
        File.rm_rf(dir)
        {:error, reason}
    end
  end

  defp capture_windows(kind, bytes, windows, dir, report) do
    windows
    |> Enum.reduce_while({:ok, []}, fn window, {:ok, acc} ->
      case capture_window(kind, bytes, window, dir) do
        {:ok, captured} ->
          report.({:window, window, length(acc) + 1, length(windows)})
          {:cont, {:ok, [captured | acc]}}

        {:error, reason} ->
          {:halt, {:error, {:extraction_window_failed, window, reason}}}
      end
    end)
    |> case do
      {:ok, captured} -> {:ok, Enum.reverse(captured)}
      error -> error
    end
  end

  # The provider is asked for exactly what production asks for; only the
  # response is intercepted, so a cached read and a live one are the same bytes.
  defp capture_window(kind, bytes, window, dir) do
    {request_opts, page_numbers} = window_opts(window)

    case Mistral.request_raw(kind, bytes, request_opts) do
      {:ok, response} ->
        name = window_name(window)
        File.write!(Path.join([dir, "raw", "#{name}.json"]), response.body)

        File.write!(
          Path.join([dir, "raw", "#{name}.meta.json"]),
          Jason.encode!(%{
            "window" => name,
            "page_numbers" => page_numbers,
            "status" => response.status
          })
        )

        {:ok, %{window: window, page_numbers: page_numbers}}

      {:error, reason, _audit} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp window_opts(:whole_document), do: {[], nil}

  # `:pages` is the provider's 0-indexed subset; `page_numbers` is the same
  # window in 1-based document pages, which is how artifacts come back numbered.
  defp window_opts(window) do
    page_numbers = Enum.to_list(window)
    {[pages: Enum.map(page_numbers, &(&1 - 1))], page_numbers}
  end

  defp window_name(:whole_document), do: "whole_document"
  defp window_name(first..last//_), do: "pages_#{pad(first)}_#{pad(last)}"

  defp pad(number), do: String.pad_leading(to_string(number), 3, "0")

  # Mirrors `Windowed`'s own rule: a document that fits in one window is read
  # whole, exactly as production reads it.
  defp plan(bytes, opts) do
    count = Keyword.get(opts, :page_count) || page_count(bytes)

    if is_integer(count) and count > Windowed.window_size() do
      Windowed.plan(count)
    else
      [:whole_document]
    end
  end

  defp page_count(bytes) do
    path = Path.join(System.tmp_dir!(), "nila_eval_#{System.unique_integer([:positive])}.pdf")
    File.write!(path, bytes)

    try do
      case System.cmd("pdfinfo", [path], stderr_to_stdout: true) do
        {output, 0} ->
          case Regex.run(~r/^Pages:\s+(\d+)/m, output) do
            [_match, count] -> String.to_integer(count)
            nil -> :unknown
          end

        _failed ->
          :unknown
      end
    after
      File.rm(path)
    end
  end

  @doc """
  Replays a cached attempt into normalized invoices.

  Everything from `map_response/3` onwards runs now, not when the bytes were
  fetched, so a merge-rule change shows up in the next score with no API call.
  """
  def replay(attempt_dir) do
    meta = attempt_dir |> Path.join("meta.json") |> File.read!() |> Jason.decode!()
    kind = String.to_existing_atom(meta["kind"])

    window_results =
      attempt_dir
      |> Path.join("raw/*.meta.json")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.map(&replay_window(&1, kind))

    with {:ok, results} <- collect(window_results) do
      {:ok, Windowed.assemble(results, meta["page_count"])}
    end
  end

  defp replay_window(meta_path, kind) do
    meta = meta_path |> File.read!() |> Jason.decode!()
    body = meta_path |> String.replace_suffix(".meta.json", ".json") |> File.read!()
    status = if is_integer(meta["status"]), do: meta["status"], else: 200
    response = %{status: status, headers: %{}, body: body}
    window = window_from_name(meta["window"])

    case Mistral.map_response(kind, response, meta["page_numbers"]) do
      {:ok, result} ->
        {:ok, %{window: window, result: result}}

      # A window may legitimately hold no invoice — a separator page, an
      # annexure tail. Its pages stay unclaimed and the ledger reports them.
      {:error, :no_invoices_extracted, _audit} when window != :whole_document ->
        {:ok, %{window: window, result: %{pages: [], images: %{}, audit: %{}}}}

      {:error, reason, _audit} ->
        {:error, {:replay_failed, meta["window"], reason}}
    end
  end

  defp window_from_name("whole_document"), do: :whole_document

  defp window_from_name("pages_" <> range) do
    [first, last] = range |> String.split("_") |> Enum.map(&String.to_integer/1)
    first..last
  end

  defp collect(results) do
    case Enum.find(results, &match?({:error, _reason}, &1)) do
      nil -> {:ok, Enum.map(results, fn {:ok, result} -> result end)}
      error -> error
    end
  end

  @doc "The newest attempt for a corpus document, or `{:error, :no_attempt}`."
  def latest_attempt(name) do
    doc = EvalCorpus.document!(name)
    id = extract_id(doc, kind!(doc))

    case @root |> Path.join("#{id}/*") |> Path.wildcard() |> Enum.sort() |> List.last() do
      nil -> {:error, {:no_attempt, name}}
      dir -> {:ok, dir}
    end
  end

  @doc """
  The cache key: the document plus everything about the request that shapes what
  comes back.

  Windowing parameters are in it because they change which pages a call sees;
  the prompt and schema fingerprints because they change what the model is asked
  for. Nothing downstream of the response is in it, by design.
  """
  def extract_id(doc, kind) do
    fingerprint = Mistral.fingerprint(kind)

    :crypto.hash(
      :sha256,
      Enum.join(
        [
          doc["sha256"],
          to_string(Mistral),
          fingerprint.model,
          to_string(Windowed.window_size()),
          to_string(Windowed.overlap()),
          fingerprint.prompt,
          fingerprint.schema
        ],
        "|"
      )
    )
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  defp attempt_id do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> String.replace(":", "-")
  end

  defp kind!(%{"kind" => "sales"}), do: :sales
  defp kind!(%{"kind" => "purchase"}), do: :purchase

  defp kind!(doc),
    do: raise(ArgumentError, "corpus document #{doc["name"]} has no extractable kind")

  defp write_meta!(dir, doc, kind, extract_id, captured, started, bytes) do
    File.write!(
      Path.join(dir, "meta.json"),
      Jason.encode!(
        %{
          "document" => doc["name"],
          "kind" => to_string(kind),
          "extract_id" => extract_id,
          "provider" => Mistral.provider(),
          "model" => Mistral.model(),
          "fingerprint" => Mistral.fingerprint(kind),
          "window_size" => Windowed.window_size(),
          "overlap" => Windowed.overlap(),
          "page_count" => doc["pages"] || page_count(bytes),
          "windows" => Enum.map(captured, &window_name(&1.window)),
          "duration_ms" => System.monotonic_time(:millisecond) - started,
          "extracted_at" =>
            DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        },
        pretty: true
      )
    )
  end
end
