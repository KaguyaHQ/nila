defmodule Nila.Eval.Segmentation do
  @moduledoc """
  Scores a segmentation against adjudicated boundaries — and scores the decider
  against *itself*.

  Accuracy alone was not enough to choose between deciders. Three runs of the
  same model, at temperature 0, over the same 28 pages produced three different
  segmentations of breeze 2026-06: bills merged in one run and split in the
  next, seven real invoices called non-invoices in one run only. Picking a
  decider on one run of one packet is how this whole line of work started going
  wrong, so stability is a measured column here, not an impression.

  Three numbers, each answering a different question:

    * **boundary F1** — did it cut the packet where the packet is cut?
    * **kind accuracy** — and did it call each page the right sort of document?
      Reported with the two error directions apart, because they are not equally
      expensive: a challan read as an invoice costs one cheap call, an invoice
      read as a challan silently deletes a purchase from the return.
    * **stability** (Rand index over page pairs, averaged over every pair of
      runs) — would it have said the same thing again? 1.0 means every run put
      the same pages together and the same pages apart.
  """

  @truth_root "eval/segmentation"

  @doc "Adjudicated segmentation for a corpus document, or `{:error, :no_truth}`."
  def truth(name) do
    path = Path.join(@truth_root, "#{name}.json")

    if File.exists?(path) do
      {:ok, path |> File.read!() |> Jason.decode!()}
    else
      {:error, {:no_truth, name}}
    end
  end

  @doc """
  Scores one run's segments against the truth.

  `segments` are `Nila.Gst.Extraction.Discovery` segments; only their pages and
  kind are read, so a decider of any shape can be scored the same way.
  """
  def score(segments, truth) do
    expected = Enum.map(truth["segments"], & &1["pages"])
    actual = Enum.map(segments, & &1.pages)

    hits = expected |> MapSet.new() |> MapSet.intersection(MapSet.new(actual)) |> MapSet.size()

    %{
      segments: length(actual),
      expected_segments: length(expected),
      boundary_precision: ratio(hits, length(actual)),
      boundary_recall: ratio(hits, length(expected)),
      boundary_f1: f1(ratio(hits, length(actual)), ratio(hits, length(expected)))
    }
    |> Map.merge(kind_scores(segments, truth))
  end

  # An invoice called a non-invoice never reaches extraction: it is a purchase
  # that vanishes with no artifact, no flag and no page in the ledger. The
  # opposite direction is a wasted call. They are counted separately so no
  # average can hide the expensive one.
  defp kind_scores(segments, truth) do
    expected = page_kinds(Enum.map(truth["segments"], &{&1["pages"], &1["kind"]}))
    actual = page_kinds(Enum.map(segments, &{&1.pages, to_string(&1.kind)}))

    pages = Map.keys(expected)

    dropped =
      Enum.filter(pages, fn page ->
        expected[page] == "invoice" and actual[page] not in ["invoice", nil]
      end)

    spurious =
      Enum.filter(pages, fn page ->
        expected[page] == "non_invoice" and actual[page] == "invoice"
      end)

    agreed = Enum.count(pages, &(expected[&1] == actual[&1]))

    %{
      kind_accuracy: ratio(agreed, length(pages)),
      invoices_dropped: Enum.sort(dropped),
      non_invoices_kept: Enum.sort(spurious)
    }
  end

  defp page_kinds(pairs) do
    Map.new(for {pages, kind} <- pairs, page <- pages, do: {page, kind})
  end

  @doc """
  Rand index over page pairs, averaged across every pair of runs.

  Comparing partitions by page *pairs* rather than by segment identity is what
  makes runs with different segment counts comparable at all: the question asked
  of every pair of pages is only "did both runs agree on whether these two
  belong together", which is exactly the judgement being tested.
  """
  def stability(runs) when length(runs) < 2, do: 1.0

  def stability(runs) do
    partitions = Enum.map(runs, &partition/1)

    pairs =
      for {a, i} <- Enum.with_index(partitions),
          {b, j} <- Enum.with_index(partitions),
          i < j,
          do: agreement(a, b)

    Enum.sum(pairs) / length(pairs)
  end

  defp partition(segments) do
    Map.new(
      for {segment, index} <- Enum.with_index(segments), page <- segment.pages, do: {page, index}
    )
  end

  defp agreement(a, b) do
    pages = a |> Map.keys() |> Enum.filter(&Map.has_key?(b, &1)) |> Enum.sort()

    page_pairs = for x <- pages, y <- pages, x < y, do: {x, y}

    case page_pairs do
      [] ->
        1.0

      page_pairs ->
        agreed =
          Enum.count(page_pairs, fn {x, y} ->
            a[x] == a[y] == (b[x] == b[y])
          end)

        agreed / length(page_pairs)
    end
  end

  @doc """
  Stricter stability, because the Rand index flatters a packet of one-page bills.

  When almost every segment is a single page, almost every page pair is "apart"
  in every run, and agreeing about that is nearly free — breeze 2026-06 scores
  0.998 across runs that visibly disagree. These two answer the question the
  eye was asking instead:

    * `identical` — the share of run pairs whose segmentation is exactly the
      same set of page runs;
    * `kind_agreement` — the share of pages every pair of runs labelled the same
      sort of document.
  """
  def agreement_rates(runs) when length(runs) < 2, do: %{identical: 1.0, kind_agreement: 1.0}

  def agreement_rates(runs) do
    pairs =
      for {a, i} <- Enum.with_index(runs), {b, j} <- Enum.with_index(runs), i < j, do: {a, b}

    identical =
      Enum.count(pairs, fn {a, b} ->
        MapSet.new(a, & &1.pages) == MapSet.new(b, & &1.pages)
      end)

    kind =
      pairs
      |> Enum.map(fn {a, b} ->
        left = page_kinds(Enum.map(a, &{&1.pages, to_string(&1.kind)}))
        right = page_kinds(Enum.map(b, &{&1.pages, to_string(&1.kind)}))
        pages = Map.keys(left)

        ratio(Enum.count(pages, &(left[&1] == right[&1])), length(pages))
      end)
      |> average()

    %{identical: ratio(identical, length(pairs)), kind_agreement: kind}
  end

  defp average([]), do: 1.0
  defp average(values), do: Float.round(Enum.sum(values) / length(values), 3)

  @doc "How often each guard had to intervene, across runs — a decider's own error rate."
  def repairs(runs) do
    runs
    |> Enum.flat_map(fn segments -> Enum.flat_map(segments, & &1.issues) end)
    |> Enum.map(fn
      {name, _detail} -> name
      {name, _from, _to} -> name
      name -> name
    end)
    |> Enum.frequencies()
  end

  defp ratio(_hits, 0), do: 0.0
  defp ratio(hits, total), do: Float.round(hits / total, 3)

  defp f1(precision, recall) when precision + recall == 0.0, do: 0.0
  defp f1(precision, recall), do: Float.round(2 * precision * recall / (precision + recall), 3)
end
