defmodule Mix.Tasks.Nila.Eval do
  @shortdoc "Scores the GSTR-1 engine against filed returns"

  @moduledoc """
  The eval loop's command surface. Logic lives in `Nila.Eval`; this is arg
  parsing and printing, mirroring the `Nila.EvalCorpus` / `mix nila.eval_corpus`
  split.

      mix nila.eval extract <name>   # run the production extractor, cache it
      mix nila.eval score <name>     # score the newest cached extraction
      mix nila.eval score --all

  `extract` calls the provider once per window and writes a new attempt under
  `tmp/eval/extractions/`; attempts are never overwritten, because the model is
  non-deterministic and an overwritten attempt is a rewritten history.

  `score` replays the cached response bytes through mapping, merging,
  normalizing, deriving and diffing — all of which run at score time, so
  re-scoring after a rule change costs no API calls and no pure edit can hide
  behind a cache hit. It writes `fields.jsonl` and `report.md` under
  `tmp/eval/runs/<run_id>/`.

  Verdicts on rows the diff cannot settle live in `eval/adjudications/`; see
  `Nila.Eval.Adjudications`.
  """

  use Mix.Task

  alias Nila.Eval

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, _invalid} = OptionParser.parse(args, strict: [all: :boolean])

    case positional do
      ["extract", name] -> extract(name)
      ["score", name] -> score_months([name])
      ["score"] -> score_all(opts)
      [] -> Mix.shell().info(@moduledoc)
      other -> Mix.raise("unknown command #{inspect(Enum.join(other, " "))}")
    end
  end

  defp extract(name) do
    Mix.shell().info("extracting #{name}")

    report = fn
      {:plan, count} ->
        Mix.shell().info("  #{count} window(s)")

      {:window, window, done, total} ->
        Mix.shell().info("  #{done}/#{total}  #{inspect(window)}")
    end

    case Nila.Eval.Extraction.run(name, on_window: report) do
      {:ok, dir} -> Mix.shell().info("\ncached → #{dir}")
      {:error, reason} -> Mix.raise("extraction failed: #{inspect(reason, limit: 8)}")
    end
  end

  defp score_all(opts) do
    opts[:all] || Mix.raise("mix nila.eval score needs <name>, or --all for every month")
    score_months(Eval.evaluable())
  end

  defp score_months(names) do
    run_id = Eval.run_id()
    Mix.shell().info("run #{run_id}\n")

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

  # A page no artifact claimed is the failure windowing exists to make loud, so
  # it is said out loud here too rather than only in the run record.
  defp warn_unaccounted(month) do
    case month.provenance["unaccounted_pages"] do
      pages when is_list(pages) and pages != [] ->
        Mix.shell().error("        unaccounted pages: #{inspect(pages)}")

      _none ->
        :ok
    end
  end
end
