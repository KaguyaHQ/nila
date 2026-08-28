defmodule Nila.Eval.Transcription do
  @moduledoc """
  Reads historical OCR attempts cached by the retired transcription pipeline.

  Current extraction uses direct vision. These functions keep old evaluation
  runs replayable without retaining a live dependency on the retired provider.
  """

  alias Nila.EvalCorpus
  alias Nila.Gst.Extraction.Transcription

  @root "tmp/eval/transcriptions"

  @doc "The newest cached attempt for the document."
  def ensure(name), do: latest_attempt(name)

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
    with {:ok, body} <- File.read(Path.join(dir, "raw.json")) do
      Transcription.from_response(body)
    end
  end

  @doc "Newest attempt, parsed."
  def latest(name) do
    with {:ok, dir} <- latest_attempt(name), {:ok, transcription} <- load(dir) do
      {:ok, transcription, dir}
    end
  end

  @doc "Historical cache key retained so existing attempts remain addressable."
  def transcribe_id(doc) do
    :crypto.hash(
      :sha256,
      Enum.join(
        [
          doc["sha256"],
          "Elixir.Nila.Gst.Extraction.Providers.Mistral",
          "mistral-ocr-latest",
          "transcription"
        ],
        "|"
      )
    )
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end
end
