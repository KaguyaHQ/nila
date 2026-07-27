defmodule Mix.Tasks.Nila.BackfillEvidence do
  @shortdoc "Renders page images for dumps extracted before rendering shipped"

  @moduledoc """
  Gives already-extracted months their scanned bills back.

      mix nila.backfill_evidence            # report what is missing, change nothing
      mix nila.backfill_evidence --run      # render, store, re-derive
      mix nila.backfill_evidence --run --dump-id 3

  Local only: it rasterizes the original still in Storage and reattaches the page
  names. No provider call, so the invoice set cannot change under a month's
  positional ids — see `Nila.Gst.Intake.EvidenceBackfill` for why that matters
  more than the cost.

  Dry by default because it rewrites dump rows and re-derives months.
  """

  use Mix.Task

  alias Nila.Gst.Intake.EvidenceBackfill

  @requirements ["app.start"]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} =
      OptionParser.parse!(argv, strict: [run: :boolean, dump_id: :integer])

    scope = if opts[:dump_id], do: [dump_id: opts[:dump_id]], else: []

    case EvidenceBackfill.pending(scope) do
      [] ->
        Mix.shell().info("Nothing to backfill — every extracted dump already names its pages.")

      dumps ->
        Enum.each(dumps, &describe/1)

        if opts[:run], do: Enum.each(dumps, &backfill/1), else: advise(dumps)
    end
  end

  defp describe(dump) do
    Mix.shell().info(
      "  dump #{dump.id}  #{dump.kind}  client #{dump.client_id}  #{dump.period}  " <>
        "#{length(dump.invoices)} invoices, no images"
    )
  end

  defp advise(dumps) do
    Mix.shell().info("\n#{length(dumps)} dump(s) missing evidence. Re-run with --run to render.")
  end

  defp backfill(dump) do
    case EvidenceBackfill.run(dump) do
      {:ok, %{pages: pages, invoices: invoices}} ->
        Mix.shell().info(
          "  ✓ dump #{dump.id}: #{pages} pages rendered, #{invoices} invoices now point at one"
        )

      {:error, reason} ->
        Mix.shell().error("  ✗ dump #{dump.id}: #{inspect(reason)}")
    end
  end
end
