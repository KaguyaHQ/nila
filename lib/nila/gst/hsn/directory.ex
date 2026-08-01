defmodule Nila.Gst.Hsn.Directory do
  @moduledoc "Versioned lookup for the portal HSN/SAC validity master."

  import Ecto.Query, only: [from: 2]

  alias Nila.Gst.Hsn.{Entry, Release}
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

  def validate(nil, _directory), do: %{status: "missing"}
  def validate("", _directory), do: %{status: "missing"}

  def validate(code, %{entries: entries, prefixes: prefixes, release: release}) do
    code = code |> to_string() |> String.trim()

    case entries[code] do
      nil ->
        status = if MapSet.member?(prefixes, code), do: "incomplete", else: "invalid"
        %{status: status, code: code, release_id: release.id}

      entry ->
        %{
          status: "valid",
          code: code,
          description: entry.description,
          kind: entry.kind,
          digits: entry.digits,
          release_id: release.id
        }
    end
  end

  def invalidate(release_id), do: :persistent_term.erase(cache_key(release_id))

  defp cache(release, key) do
    entries =
      Repo.all(from e in Entry, where: e.release_id == ^release.id)
      |> Map.new(&{&1.code, &1})

    prefixes =
      entries
      |> Map.keys()
      |> Enum.reduce(MapSet.new(), fn code, prefixes ->
        1..(String.length(code) - 1)
        |> Enum.reduce(prefixes, fn length, acc ->
          MapSet.put(acc, String.slice(code, 0, length))
        end)
      end)

    directory = %{release: release, entries: entries, prefixes: prefixes}
    :persistent_term.put(key, directory)
    directory
  end

  defp cache_key(release_id), do: {__MODULE__, release_id}
end
