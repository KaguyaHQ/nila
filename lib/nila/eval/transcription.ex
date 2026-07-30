defmodule Nila.Eval.Transcription do
  @moduledoc """
  Caches the pure-OCR read of a corpus document.

  Transcription is the one stage that must touch pixels, so it is the one stage
  that cannot be re-run for free. Everything after it — segmentation, extraction,
  grounding — reads this cache, which means a prompt or guard change costs no OCR
  and every stage is scored against exactly the text the others saw.

  Attempts are never overwritten, for the same reason
  `Nila.Eval.Extraction` never overwrites: OCR is not deterministic either. The
  windowed runs proved it — the same page read in two overlapping windows came
  back with different text, and once in the corpus with a different *document
  type*. `latest/1` is what the pipeline reads; older attempts stay on disk as
  the record of what was true when a score was taken.
  """

  alias Nila.EvalCorpus
  alias Nila.Gst.Extraction.Providers.Mistral
  alias Nila.Gst.Extraction.Transcription

  @root "tmp/eval/transcriptions"

  @doc "Reads a corpus document with the annotation layer off, writing a new attempt."
  def run(name) do
    doc = EvalCorpus.document!(name)
    bytes = name |> EvalCorpus.fetch!() |> File.read!()

    started = System.monotonic_time(:millisecond)
    dir = Path.join([@root, transcribe_id(doc), attempt_id()])

    case Mistral.transcribe_raw(bytes, filename: Path.basename(doc["key"])) do
      {:ok, %{status: status} = response} when status in 200..299 ->
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, "raw.json"), response.body)
        write_meta!(dir, doc, response, started)
        {:ok, dir}

      {:ok, response} ->
        {:error, {:transcription_failed, response.status, String.slice(response.body, 0, 400)}}

      {:error, reason, _audit} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "The newest attempt, running one if the document has never been transcribed."
  def ensure(name) do
    case latest_attempt(name) do
      {:ok, dir} -> {:ok, dir}
      {:error, {:no_attempt, _name}} -> run(name)
    end
  end

  @doc "The newest attempt for a corpus document."
  def latest_attempt(name) do
    id = name |> EvalCorpus.document!() |> transcribe_id()

    case @root |> Path.join("#{id}/*") |> Path.wildcard() |> Enum.sort() |> List.last() do
      nil -> {:error, {:no_attempt, name}}
      dir -> {:ok, dir}
    end
  end

  @doc "Parses a cached attempt into a `Nila.Gst.Extraction.Transcription`."
  def load(dir) do
    dir |> Path.join("raw.json") |> File.read!() |> Transcription.from_response()
  end

  @doc "Newest attempt, parsed."
  def latest(name) do
    with {:ok, dir} <- latest_attempt(name), {:ok, transcription} <- load(dir) do
      {:ok, transcription, dir}
    end
  end

  @doc "Cache key: the document and everything about the request that shapes the text."
  def transcribe_id(doc) do
    fingerprint = Mistral.transcription_fingerprint()

    :crypto.hash(
      :sha256,
      Enum.join([doc["sha256"], to_string(Mistral), fingerprint.model, fingerprint.mode], "|")
    )
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  defp write_meta!(dir, doc, response, started) do
    {:ok, transcription} = Transcription.from_response(response.body)

    File.write!(
      Path.join(dir, "meta.json"),
      Jason.encode!(
        %{
          "document" => doc["name"],
          "provider" => Mistral.provider(),
          "model" => Mistral.model(),
          "mode" => "transcription",
          "expected_pages" => doc["pages"],
          "pages" => Transcription.page_count(transcription),
          "duration_ms" => System.monotonic_time(:millisecond) - started,
          "transcribed_at" => stamp()
        },
        pretty: true
      )
    )
  end

  defp attempt_id, do: String.replace(stamp(), ":", "-")

  defp stamp do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end
end
