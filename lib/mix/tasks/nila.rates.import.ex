defmodule Mix.Tasks.Nila.Rates.Import do
  use Mix.Task

  @shortdoc "Stages a GST candidate-rate notification release"

  @moduledoc """
  Imports Notification 09/2025-Integrated Tax (Rate) as an immutable staged release.

      mix nila.rates.import path/to/09-2025-ITR-Eng.pdf --source-url URL
  """

  alias Nila.Gst.Rates.Importer

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: [source_url: :string])

    case {positional, invalid} do
      {[path], []} -> do_import(path, opts)
      _ -> Mix.raise("usage: mix nila.rates.import PATH [--source-url URL]")
    end
  end

  defp do_import(path, opts) do
    Mix.Task.run("app.start")

    case Importer.import(path, opts) do
      {:ok, %{release: release, rules: count, automatic: automatic, review: review}} ->
        Mix.shell().info(
          "Staged GST rate release ##{release.id}: #{count} rules " <>
            "(#{automatic} automatic, #{review} review-required), effective " <>
            "#{release.effective_from}."
        )

      {:error, :duplicate_release} ->
        Mix.raise("this exact notification has already been imported")

      {:error, reason} ->
        Mix.raise("GST rate import failed: #{inspect(reason)}")
    end
  end
end
