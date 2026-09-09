defmodule Mix.Tasks.Nila.EvalCorpus do
  @shortdoc "Manage the private eval corpus (status | pull | add <pdf> <truth.json> | attach <name> <truth.json>)"

  @moduledoc """
  Real client packets for OCR evals live in the `nila-eval-corpus` R2 bucket,
  registered in `eval/corpus.json`. Probes and the benchmark fetch them via
  `Nila.EvalCorpus` into `~/.cache/nila/eval-corpus`.

  Browse client sales PDFs under `sales/real/`, named `<client>-<period>.pdf`.
  Constructed Tally packets live under `sales/synthetic/`, named for their test cases.
  Purchase PDFs remain under `purchase/`. Status counts real and synthetic separately.
  The manifest's `source_type` is `real` or `synthetic`; packet IDs stay stable.

      mix nila.eval_corpus                # status: what exists, what's evaluable
      mix nila.eval_corpus pull           # fetch everything missing, verify checksums
      mix nila.eval_corpus add ~/Downloads/packet.pdf ~/Downloads/returns_R2B_....json
      mix nila.eval_corpus attach breeze-2026-06-purchase ~/Downloads/returns_R2B_....json

  `add` onboards a real client month in one step: it reads the portal truth JSON (filed
  GSTR-1 for sales, GSTR-2B for purchase) to infer client/period/kind, uploads
  the PDF, places the truth under `test/fixtures/`, and updates the manifest.
  `attach` adds a truth to a packet already in the corpus. Both leave changes
  uncommitted — review the diff and commit.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:ex_aws)
    {:ok, _} = Application.ensure_all_started(:req)

    case args do
      [] ->
        Nila.EvalCorpus.status()

      ["status"] ->
        Nila.EvalCorpus.status()

      ["pull"] ->
        Nila.EvalCorpus.pull()

      ["add", pdf, truth] ->
        Nila.EvalCorpus.add!(pdf, truth)

      ["add", pdf, client, period, kind] ->
        Nila.EvalCorpus.add!(pdf, client, period, kind)

      ["attach", name, truth] ->
        Nila.EvalCorpus.attach!(name, truth)

      ["open", name] ->
        Nila.EvalCorpus.open!(name)

      _ ->
        Mix.raise(
          "usage: mix nila.eval_corpus [status | pull | add <pdf> <truth.json> | attach <name> <truth.json> | open <name>]"
        )
    end
  end
end
