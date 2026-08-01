defmodule Mix.Tasks.Nila.Hsn.Import do
  use Mix.Task

  @shortdoc "Stages a portal HSN/SAC workbook release"

  @moduledoc """
  Imports the portal HSN/SAC workbook as an immutable staged release.

      mix nila.hsn.import path/to/HSN_SAC.xlsx
      mix nila.hsn.import path/to/HSN_SAC.xlsx --source-url URL
  """

  alias Nila.Gst.Hsn.Importer

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: [source_url: :string])

    case {positional, invalid} do
      {[path], []} -> do_import(path, opts)
      _ -> Mix.raise("usage: mix nila.hsn.import PATH [--source-url URL]")
    end
  end

  defp do_import(path, opts) do
    Mix.Task.run("app.start")

    case Importer.import(path, opts) do
      {:ok,
       %{
         release: release,
         entries: count,
         source_rows: source_rows,
         duplicate_rows: duplicate_rows,
         diff: diff
       }} ->
        Mix.shell().info(
          "Staged HSN/SAC release ##{release.id}: #{count} unique entries from " <>
            "#{source_rows} source rows (#{duplicate_rows} duplicate code rows normalized; " <>
            "#{diff.added} added, #{diff.removed} removed, " <>
            "#{diff.descriptions_changed} descriptions changed)."
        )

      {:error, :duplicate_release} ->
        Mix.raise("this exact workbook has already been imported")

      {:error, reason} ->
        Mix.raise("HSN/SAC import failed: #{inspect(reason)}")
    end
  end
end
