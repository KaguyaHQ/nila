defmodule Nila.Gst.Rates.Directory do
  @moduledoc "Versioned lookup for imported GST candidate-rate rules."

  import Ecto.Query, only: [from: 2]

  alias Nila.Gst.Rates.{Release, Rule}
  alias Nila.Repo

  def active_release do
    Repo.fetch_one(from r in Release, where: r.status == "active", limit: 1)
  end

  def active do
    with {:ok, release} <- active_release(), do: load(release)
  end

  def load(release_id) when is_integer(release_id) do
    with {:ok, release} <- Repo.fetch(Release, release_id), do: load(release)
  end

  def load(%Release{} = release) do
    key = cache_key(release.id)

    case :persistent_term.get(key, nil) do
      nil -> {:ok, cache(release, key)}
      directory -> {:ok, directory}
    end
  end

  def invalidate(release_id), do: :persistent_term.erase(cache_key(release_id))

  defp cache(release, key) do
    rules =
      Repo.all(
        from r in Rule,
          where: r.release_id == ^release.id,
          order_by: [asc: r.schedule, asc: r.serial_number]
      )

    directory = %{release: release, rules: rules}
    :persistent_term.put(key, directory)
    directory
  end

  defp cache_key(release_id), do: {__MODULE__, release_id}
end
