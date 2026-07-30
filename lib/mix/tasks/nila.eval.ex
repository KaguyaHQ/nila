defmodule Mix.Tasks.Nila.Eval do
  @shortdoc "Scores the GSTR-1 engine against filed returns"

  @moduledoc """
  The eval loop's command surface. Logic lives in `Nila.Eval`; this is arg
  parsing and printing, mirroring the `Nila.EvalCorpus` / `mix nila.eval_corpus`
  split.

      mix nila.eval bridge                    # reproduce pre-lift baselines
      mix nila.eval bridge --header production # same, with the production header
      mix nila.eval extract <name>            # run the production extractor, cache it
      mix nila.eval score <name>              # score a cached extraction
      mix nila.eval score --all
      mix nila.eval report <client> <period>  # score archived Llama artifacts

  `bridge` is the faithfulness control: it re-scores the archived page artifacts
  and asserts the numbers the retired script produced. Run it under both headers
  — `filed` proves the lift into `lib/` changed nothing, `production` proves the
  header swap is score-neutral.

  `extract` calls the provider once per window and writes a new attempt under
  `tmp/eval/extractions/`; attempts are never overwritten. `score` replays the
  newest attempt through mapping, merging, normalizing, deriving and diffing —
  all of which run at score time, so re-scoring after a rule change costs no API
  calls.

  `report` is the pre-sweep path over the archived Llama artifacts.
  """

  use Mix.Task

  alias Nila.Eval

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, _invalid} =
      OptionParser.parse(args, strict: [header: :string, all: :boolean])

    case positional do
      ["bridge"] -> bridge(opts)
      ["extract", name] -> extract(name)
      ["score", name] -> score_months([name])
      ["score"] -> score_all(opts)
      ["report", client, period] -> report_months([{client, period}])
      ["report"] -> report_all(opts)
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
    "#{month.raw["score"]}%  #{length(month.mismatches)} mismatches across " <>
      "#{length(month.by_invoice)} invoices  → #{month.report_path}"
  end

  # A page no artifact claimed is the failure windowing exists to make loud, so
  # it is said out loud here too rather than only in the run record.
  defp warn_unaccounted(month) do
    case month.provenance["unaccounted_pages"] do
      [] -> :ok
      nil -> :ok
      pages -> Mix.shell().error("        unaccounted pages: #{inspect(pages)}")
    end
  end

  defp report_all(opts) do
    opts[:all] ||
      Mix.raise("mix nila.eval report needs <client> <period>, or --all for every month")

    Eval.baselines() |> Map.keys() |> Enum.sort() |> report_months()
  end

  defp report_months(months) do
    run_id = Eval.run_id()
    Mix.shell().info("run #{run_id}\n")

    Enum.each(months, fn {client, period} ->
      case Eval.score_archived(client, period, run_id) do
        {:ok, month} ->
          Mix.shell().info(
            "  #{String.pad_trailing("#{client} #{period}", 18)} " <>
              "#{month.raw["score"]}%  #{length(month.mismatches)} mismatches across " <>
              "#{length(month.by_invoice)} invoices  → #{month.report_path}"
          )

        {:error, reason} ->
          Mix.shell().error("  #{client} #{period}  #{inspect(reason)}")
      end
    end)
  end

  defp bridge(opts) do
    header = header!(opts[:header] || "filed")
    Mix.shell().info("bridge (header: #{header})\n")

    case Eval.bridge(header: header) do
      {:ok, results} ->
        Enum.each(results, &report/1)
        Mix.shell().info("\nall #{length(results)} months reproduced their baseline")

      {:error, results} ->
        Enum.each(results, &report/1)
        failed = Enum.reject(results, & &1.matched?)

        Mix.raise("""
        #{length(failed)} of #{length(results)} months did not reproduce.

        This is a finding, not a number to tune: under --header filed it means the
        lifted differ scores differently from the script it replaced; under
        --header production it means the diff now compares a field the production
        header supplies a fallback for. Investigate before going further.
        """)
    end
  end

  defp header!("filed"), do: :filed
  defp header!("production"), do: :production

  defp header!(other),
    do: Mix.raise("--header must be filed or production, got #{inspect(other)}")

  defp report(%{matched?: true} = result) do
    Mix.shell().info(
      "  ok    #{label(result)}  #{fmt(result.actual)}  (#{row_count(result)} rows)"
    )
  end

  defp report(%{actual: nil} = result) do
    Mix.shell().error("  ERR   #{label(result)}  #{inspect(result[:error])}")
  end

  defp report(result) do
    Mix.shell().error(
      "  DIFF  #{label(result)}  expected #{fmt(result.expected)}  got #{fmt(result.actual)}"
    )
  end

  defp label(%{client: client, period: period}),
    do: String.pad_trailing("#{client} #{period}", 18)

  defp fmt(score), do: String.pad_leading("#{score}%", 7)

  defp row_count(%{rows: rows}), do: length(rows)
end
