defmodule Mix.Tasks.Nila.Eval do
  @shortdoc "Scores the GSTR-1 engine against filed returns"

  @moduledoc """
  The eval loop's command surface. Logic lives in `Nila.Eval`; this is arg
  parsing and printing, mirroring the `Nila.EvalCorpus` / `mix nila.eval_corpus`
  split.

      mix nila.eval bridge                    # reproduce pre-lift baselines
      mix nila.eval bridge --header production # same, with the production header

  `bridge` is the faithfulness control: it re-scores the archived page artifacts
  and asserts the numbers the retired script produced. Run it under both headers
  — `filed` proves the lift into `lib/` changed nothing, `production` proves the
  header swap is score-neutral.
  """

  use Mix.Task

  alias Nila.Eval

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, _invalid} = OptionParser.parse(args, strict: [header: :string])

    case positional do
      ["bridge"] -> bridge(opts)
      [] -> Mix.shell().info(@moduledoc)
      other -> Mix.raise("unknown command #{inspect(Enum.join(other, " "))}")
    end
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
