defmodule Nila.Gst.Hsn.Importer do
  @moduledoc "Imports and activates immutable portal HSN/SAC workbook releases."

  import Ecto.Query, only: [from: 2]

  alias Nila.Gst.Hsn.{Directory, Entry, Release, Xlsx}
  alias Nila.Repo

  def import(path, opts \\ []) do
    with {:ok, bytes} <- File.read(path),
         hash = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower),
         {:error, :not_found} <- Repo.fetch_by(Release, file_sha256: hash),
         {:ok, entries} <- Xlsx.read(path) do
      persist(path, hash, entries, opts)
    else
      {:ok, %Release{}} -> {:error, :duplicate_release}
      {:error, reason} -> {:error, reason}
    end
  end

  def activate(release_id) do
    Repo.transact(fn ->
      with {:ok, release} <- fetch_staged_for_update(release_id) do
        now = DateTime.utc_now()

        Repo.update_all(
          from(r in Release, where: r.status == "active"),
          set: [status: "superseded"]
        )

        release =
          release
          |> Release.changeset(%{status: "active", activated_at: now})
          |> Repo.update!()

        Directory.invalidate(release.id)
        {:ok, release}
      end
    end)
  end

  defp persist(path, hash, parsed_entries, opts) do
    entries = parsed_entries |> deduplicate() |> hierarchy()
    diff = diff(entries)
    now = DateTime.utc_now()

    Repo.transact(fn ->
      release =
        %Release{}
        |> Release.changeset(%{
          source_name: Path.basename(path),
          source_url: Keyword.get(opts, :source_url),
          file_sha256: hash,
          observed_at: Keyword.get(opts, :observed_at, now)
        })
        |> Repo.insert!()

      entries
      |> Enum.map(fn entry ->
        entry
        |> Map.put(:release_id, release.id)
        |> Map.put(:inserted_at, now)
      end)
      |> Enum.chunk_every(1_000)
      |> Enum.each(&Repo.insert_all(Entry, &1))

      {:ok,
       %{
         release: release,
         entries: length(entries),
         source_rows: length(parsed_entries),
         duplicate_rows: length(parsed_entries) - length(entries),
         diff: diff
       }}
    end)
  end

  defp deduplicate(entries) do
    entries
    |> Enum.group_by(&{&1.kind, &1.code})
    |> Enum.map(fn {_key, duplicates} ->
      Enum.min_by(duplicates, &String.length(&1.description))
    end)
    |> Enum.sort_by(&{&1.kind, &1.code})
  end

  defp hierarchy(entries) do
    codes_by_kind =
      entries
      |> Enum.group_by(& &1.kind, & &1.code)
      |> Map.new(fn {kind, codes} -> {kind, MapSet.new(codes)} end)

    parent_prefixes_by_kind =
      Map.new(codes_by_kind, fn {kind, codes} ->
        prefixes =
          Enum.reduce(codes, MapSet.new(), fn code, acc ->
            allowed_lengths(kind)
            |> Enum.filter(&(&1 < String.length(code)))
            |> Enum.reduce(acc, fn length, prefixes ->
              MapSet.put(prefixes, String.slice(code, 0, length))
            end)
          end)

        {kind, prefixes}
      end)

    Enum.map(entries, fn entry ->
      codes = codes_by_kind[entry.kind]

      parent_code =
        entry.kind
        |> allowed_lengths()
        |> Enum.filter(&(&1 < String.length(entry.code)))
        |> Enum.sort(:desc)
        |> Enum.find_value(fn length ->
          prefix = String.slice(entry.code, 0, length)
          if MapSet.member?(codes, prefix), do: prefix
        end)

      entry
      |> Map.put(:digits, String.length(entry.code))
      |> Map.put(:parent_code, parent_code)
      |> Map.put(:has_children, MapSet.member?(parent_prefixes_by_kind[entry.kind], entry.code))
    end)
  end

  defp allowed_lengths("hsn"), do: [2, 4, 6, 8]
  defp allowed_lengths("sac"), do: [2, 4, 6]

  defp diff(entries) do
    case Directory.active_release() do
      {:error, :not_found} ->
        %{added: length(entries), removed: 0, descriptions_changed: 0}

      {:ok, release} ->
        previous =
          Repo.all(from e in Entry, where: e.release_id == ^release.id)
          |> Map.new(&{{&1.kind, &1.code}, &1.description})

        incoming = Map.new(entries, &{{&1.kind, &1.code}, &1.description})

        %{
          added:
            Enum.count(incoming, fn {key, _description} -> not Map.has_key?(previous, key) end),
          removed:
            Enum.count(previous, fn {key, _description} -> not Map.has_key?(incoming, key) end),
          descriptions_changed:
            Enum.count(incoming, fn {key, description} ->
              Map.has_key?(previous, key) and previous[key] != description
            end)
        }
    end
  end

  defp fetch_staged_for_update(release_id) do
    Repo.fetch_one(
      from r in Release,
        where: r.id == ^release_id and r.status == "staged",
        lock: "FOR UPDATE"
    )
  end
end
