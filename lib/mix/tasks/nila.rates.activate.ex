defmodule Mix.Tasks.Nila.Rates.Activate do
  use Mix.Task

  @shortdoc "Activates a staged GST candidate-rate release"

  @moduledoc """
  Activates one staged release and supersedes the currently active release.

      mix nila.rates.activate RELEASE_ID
  """

  alias Nila.Gst.Rates.Importer

  @impl Mix.Task
  def run([release_id]) do
    Mix.Task.run("app.start")

    with {release_id, ""} <- Integer.parse(release_id),
         {:ok, release} <- Importer.activate(release_id) do
      Mix.shell().info(
        "Activated GST rate release ##{release.id} (#{release.notification_number})."
      )
    else
      :error -> Mix.raise("RELEASE_ID must be an integer")
      {:error, :not_found} -> Mix.raise("staged release not found")
      {:error, reason} -> Mix.raise("GST rate activation failed: #{inspect(reason)}")
    end
  end

  def run(_args), do: Mix.raise("usage: mix nila.rates.activate RELEASE_ID")
end
