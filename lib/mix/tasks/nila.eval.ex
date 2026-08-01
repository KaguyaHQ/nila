defmodule Mix.Tasks.Nila.Eval do
  @shortdoc "Scores the GSTR-1 engine against filed returns"

  @moduledoc """
  The eval loop's command surface. Logic lives in `Nila.Eval`; this is arg
  parsing and printing, mirroring the `Nila.EvalCorpus` / `mix nila.eval_corpus`
  split.

      mix nila.eval extract <name>   # run the production extractor, cache it
      mix nila.eval score <name>     # score the newest cached extraction
      mix nila.eval score --all

      mix nila.eval transcribe <name>          # pure OCR, no annotation, cached
      mix nila.eval segment <name> [--runs 5] [--shape per_page|whole_dump]

  `extract` runs the production transcribe → discover → extract → verify path
  and writes a new attempt under `tmp/eval/segmented/`. Attempts are never
  overwritten because the model is non-deterministic and an overwritten attempt
  is a rewritten history.

  `score` replays the cached response bytes through mapping, verification,
  normalizing, deriving and diffing — all of which run at score time, so
  re-scoring after a rule change costs no API calls and no pure edit can hide
  behind a cache hit. It writes `fields.jsonl` and `report.md` under
  `tmp/eval/runs/<run_id>/`.

  Verdicts on rows the diff cannot settle live in `eval/adjudications/`; see
  `Nila.Eval.Adjudications`.
  """

  use Mix.Task

  alias Nila.Eval
  alias Nila.Gst.Extraction.Discovery
  alias Nila.Gst.Extraction.Transcription

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, invalid} =
      OptionParser.parse(args, strict: [all: :boolean, runs: :integer, shape: :string])

    if invalid != [], do: Mix.raise("invalid options #{inspect(invalid)}")

    case positional do
      ["extract", name] -> extract(name, opts)
      ["transcribe", name] -> transcribe(name)
      ["segment", name] -> segment(name, opts)
      ["score", name] -> score_months([name])
      ["score"] -> score_all(opts)
      [] -> Mix.shell().info(@moduledoc)
      other -> Mix.raise("unknown command #{inspect(Enum.join(other, " "))}")
    end
  end

  defp transcribe(name) do
    Mix.shell().info("transcribing #{name} (pure OCR, no annotation)")

    case Nila.Eval.Transcription.run(name) do
      {:ok, dir} ->
        meta = dir |> Path.join("meta.json") |> File.read!() |> Jason.decode!()
        Mix.shell().info("  #{meta["pages"]} pages in #{meta["duration_ms"]}ms")
        Mix.shell().info("\ncached → #{dir}")

      {:error, reason} ->
        Mix.raise("transcription failed: #{inspect(reason, limit: 8)}")
    end
  end

  # Segmentation on its own, scored against adjudicated boundaries and against
  # its own repeat runs. The stage split exists so a bad boundary and a bad read
  # are never the same number; the repeat runs exist because this decider was
  # picked once on one run of one packet and that is how the last three days
  # went wrong.
  defp segment(name, opts) do
    runs = opts[:runs] || 1
    shape = shape(opts)

    with {:ok, dir} <- Nila.Eval.Transcription.ensure(name),
         {:ok, transcription} <- Nila.Eval.Transcription.load(dir) do
      results =
        Enum.map(1..runs, fn index ->
          case Discovery.discover(transcription, shape: shape) do
            {:ok, result} ->
              if runs > 1, do: Mix.shell().info("run #{index}/#{runs}")
              print_segments(result)
              result

            {:error, reason} ->
              Mix.raise("segmentation failed: #{inspect(reason, limit: 8)}")
          end
        end)

      report_scores(name, shape, transcription, results)
    else
      {:error, reason} -> Mix.raise("segmentation failed: #{inspect(reason, limit: 8)}")
    end
  end

  defp shape(opts) do
    case opts[:shape] do
      nil -> :per_page
      "per_page" -> :per_page
      "whole_dump" -> :whole_dump
      other -> Mix.raise("unknown --shape #{inspect(other)} (per_page | whole_dump)")
    end
  end

  defp print_segments(%{segments: segments, violations: violations}) do
    Enum.each(segments, fn segment ->
      pages = Enum.map_join(segment.pages, ",", &to_string/1)

      Mix.shell().info(
        "  #{String.pad_trailing(pages, 12)} #{String.pad_trailing(to_string(segment.kind), 12)} " <>
          "#{String.pad_trailing(segment.invoice_no || "-", 20)} #{grounded(segment)}#{issues(segment)}"
      )
    end)

    Enum.each(violations, &Mix.shell().error("  violation: #{Discovery.describe(&1)}"))
    Mix.shell().info("")
  end

  defp report_scores(name, shape, transcription, results) do
    runs = Enum.map(results, & &1.segments)

    Mix.shell().info(
      "#{Transcription.page_count(transcription)} pages, #{length(runs)} run(s), shape #{shape}"
    )

    case Nila.Eval.Segmentation.truth(name) do
      {:ok, truth} ->
        Enum.each(runs, fn segments ->
          score = Nila.Eval.Segmentation.score(segments, truth)

          Mix.shell().info(
            "  boundary F1 #{score.boundary_f1}  (#{score.segments}/#{score.expected_segments} segments)  " <>
              "kind #{score.kind_accuracy}"
          )

          if score.invoices_dropped != [] do
            Mix.shell().error(
              "    invoices dropped as non-invoice: #{Enum.join(score.invoices_dropped, ",")}"
            )
          end

          if score.non_invoices_kept != [] do
            Mix.shell().info(
              "    non-invoices kept (cheap): #{Enum.join(score.non_invoices_kept, ",")}"
            )
          end
        end)

      {:error, {:no_truth, _name}} ->
        Mix.shell().info("  no adjudicated boundaries in eval/segmentation/#{name}.json")
    end

    if length(runs) > 1 do
      rates = Nila.Eval.Segmentation.agreement_rates(runs)

      Mix.shell().info(
        "  stability: rand #{Float.round(Nila.Eval.Segmentation.stability(runs), 3)}  " <>
          "identical #{rates.identical}  kind agreement #{rates.kind_agreement}"
      )
    end

    case Nila.Eval.Segmentation.repairs(runs) do
      repairs when repairs == %{} -> Mix.shell().info("  guards: silent")
      repairs -> Mix.shell().info("  guards: #{inspect(repairs, charlists: :as_lists)}")
    end
  end

  defp grounded(%{grounded?: true}), do: "grounded"
  defp grounded(%{grounded?: false}), do: "NOT ON PAGE"
  defp grounded(_segment), do: ""

  defp issues(%{issues: []}), do: ""
  defp issues(%{issues: issues}), do: "  " <> inspect(issues, limit: 5, charlists: :as_lists)

  defp extract(name, opts) do
    shape = shape(opts)
    Mix.shell().info("extracting #{name} (segmented, #{shape})")

    report = fn
      {:transcribed, pages} ->
        Mix.shell().info("  transcribed #{pages} pages")
        :ok

      {:segmented, segments, violations} ->
        Mix.shell().info(
          "  #{length(segments)} segments, #{Enum.count(segments, &(&1.kind == :invoice))} invoices"
        )

        Enum.each(violations, &Mix.shell().error("  violation: #{Discovery.describe(&1)}"))
        :ok

      {:segment, done, total} ->
        Mix.shell().info("  #{done}/#{total} extracted")
        :ok
    end

    case Nila.Eval.Segmented.run(name, on_event: report, shape: shape) do
      {:ok, dir} -> Mix.shell().info("\ncached → #{dir}")
      {:error, reason} -> Mix.raise("segmented extraction failed: #{inspect(reason, limit: 8)}")
    end
  end

  defp score_all(opts) do
    opts[:all] || Mix.raise("mix nila.eval score needs <name>, or --all for every month")
    score_months(Eval.evaluable())
  end

  defp score_months(names) do
    run_id = Eval.run_id()
    Mix.shell().info("run #{run_id} (segmented)\n")

    Enum.each(names, fn name ->
      case Eval.score(name, run_id) do
        {:ok, month} ->
          Mix.shell().info("  #{String.pad_trailing(name, 26)} #{summary(month)}")
          warn_unaccounted(month)

        {:error, reason} ->
          Mix.shell().error("  #{String.pad_trailing(name, 26)} #{inspect(reason, limit: 6)}")
      end
    end)
  end

  defp summary(month) do
    "#{month.raw["score"]}%#{adjusted(month)}  #{length(month.mismatches)} mismatches across " <>
      "#{length(month.by_invoice)} invoices  → #{month.report_path}"
  end

  defp adjusted(%{adjusted: nil}), do: ""
  defp adjusted(%{adjusted: adjusted}), do: " raw / #{adjusted["score"]}% adjusted"

  # A page no artifact claimed is an extraction gap, so it is said out loud
  # here rather than only in the run record.
  defp warn_unaccounted(month) do
    case month.provenance["unaccounted_pages"] do
      pages when is_list(pages) and pages != [] ->
        Mix.shell().error("        unaccounted pages: #{inspect(pages)}")

      _none ->
        :ok
    end
  end
end
