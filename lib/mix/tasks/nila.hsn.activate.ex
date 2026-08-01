defmodule Mix.Tasks.Nila.Hsn.Activate do
  use Mix.Task

  @shortdoc "Activates a staged HSN/SAC release"

  @moduledoc """
  Activates one staged release and supersedes the currently active release.

      mix nila.hsn.activate RELEASE_ID
  """

  alias Nila.Gst.Hsn.Importer

  @impl Mix.Task
  def run([release_id]) do
    Mix.Task.run("app.start")

    with {release_id, ""} <- Integer.parse(release_id),
         {:ok, release} <- Importer.activate(release_id) do
      Mix.shell().info("Activated HSN/SAC release ##{release.id} (#{release.source_name}).")
    else
      :error -> Mix.raise("RELEASE_ID must be an integer")
      {:error, :not_found} -> Mix.raise("staged release not found")
      {:error, reason} -> Mix.raise("HSN/SAC activation failed: #{inspect(reason)}")
    end
  end

  def run(_args), do: Mix.raise("usage: mix nila.hsn.activate RELEASE_ID")
end
