defmodule Nila.Eval.SourceQuality do
  @moduledoc """
  Reports OCR confidence metrics from a cached transcription attempt.

  This is measurement only. It assigns no quality label and changes no
  production routing.
  """

  alias Nila.Eval.Transcription, as: EvalTranscription

  @doc "Loads one cached transcription attempt and ranks its pages worst-first."
  def report(name, opts \\ []) do
    with {:ok, dir} <- attempt(name, opts),
         :ok <- validate_attempt(name, dir),
         {:ok, transcription} <- EvalTranscription.load(dir) do
      {:ok, %{attempt: dir, pages: pages(transcription)}}
    end
  end

  @doc "Ranks parsed transcription pages by all-word average confidence, worst-first."
  def pages(transcription) do
    transcription.pages
    |> Map.values()
    |> Enum.map(&page_metrics/1)
    |> Enum.sort_by(fn page ->
      case page["all_word_average_confidence_score"] do
        nil -> {1, 0, page["page"]}
        score -> {0, score, page["page"]}
      end
    end)
  end

  defp page_metrics(page) do
    provider = if is_map(page.confidence), do: page.confidence, else: %{}
    tables = if is_list(page.tables), do: page.tables, else: []
    scores = word_confidences(provider) ++ Enum.flat_map(tables, &word_confidences/1)
    quality = confidence_metrics(scores)

    %{
      "page" => page.number,
      "provider_average_confidence_score" =>
        confidence_score(provider["average_page_confidence_score"]),
      "all_word_average_confidence_score" => quality.average,
      "all_word_p10_confidence_score" => quality.p10,
      "under_70_word_share" => quality.under_70_share,
      "all_word_count" => quality.count
    }
  end

  defp word_confidences(container) when is_map(container) do
    case container["word_confidence_scores"] do
      scores when is_list(scores) ->
        Enum.flat_map(scores, fn
          %{"confidence" => score} -> confidence_values(score)
          _invalid -> []
        end)

      _invalid ->
        []
    end
  end

  defp word_confidences(_invalid), do: []

  defp confidence_values(score) when is_number(score) and score >= 0 and score <= 1,
    do: [score / 1]

  defp confidence_values(_invalid), do: []

  defp confidence_metrics([]), do: %{count: 0, average: nil, p10: nil, under_70_share: nil}

  defp confidence_metrics(scores) do
    count = length(scores)

    %{
      count: count,
      average: Enum.sum(scores) / count,
      p10: scores |> Enum.sort() |> Enum.at(trunc((count - 1) * 0.10)),
      under_70_share: Enum.count(scores, &(&1 < 0.70)) / count
    }
  end

  defp confidence_score(score) when is_number(score) and score >= 0 and score <= 1,
    do: score / 1

  defp confidence_score(_invalid), do: nil

  defp attempt(name, opts) do
    case Keyword.fetch(opts, :transcription_attempt) do
      {:ok, dir} -> {:ok, dir}
      :error -> EvalTranscription.latest_attempt(name)
    end
  end

  defp validate_attempt(name, dir) do
    with {:ok, body} <- File.read(Path.join(dir, "meta.json")),
         {:ok, meta} <- Jason.decode(body) do
      case meta["document"] do
        ^name -> :ok
        actual -> {:error, {:transcription_attempt_mismatch, name, actual}}
      end
    end
  end
end
