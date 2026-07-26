defmodule Mix.Tasks.Nila.EvalCorpus do
  @shortdoc "Manage the private eval corpus (status | pull | push <key> <file> [ground-truth])"

  @moduledoc """
  Real client packets for OCR evals live in the `nila-eval-corpus` R2 bucket,
  registered in `bench/corpus.json`. Probes and the benchmark fetch them via
  `Nila.EvalCorpus` into `~/.cache/nila/eval-corpus`.

      mix nila.eval_corpus            # status: cached / missing per document
      mix nila.eval_corpus pull       # fetch everything missing, verify checksums
      mix nila.eval_corpus push breeze/2026-06/purchase.pdf ~/Downloads/june.pdf \\
        test/fixtures/gstr1/breeze/2026-06/returns_...json

  `push` uploads and prints the manifest entry — paste it into
  `bench/corpus.json` and commit alongside the ground-truth fixture.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:ex_aws)
    {:ok, _} = Application.ensure_all_started(:req)

    case args do
      [] -> Nila.EvalCorpus.status()
      ["status"] -> Nila.EvalCorpus.status()
      ["pull"] -> Nila.EvalCorpus.pull()
      ["push", key, file] -> Nila.EvalCorpus.push!(key, file)
      ["push", key, file, ground_truth] -> Nila.EvalCorpus.push!(key, file, ground_truth)
      _ -> Mix.raise("usage: mix nila.eval_corpus [status | pull | push <key> <file> [gt]]")
    end
  end
end
