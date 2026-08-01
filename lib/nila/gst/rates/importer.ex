defmodule Nila.Gst.Rates.Importer do
  @moduledoc "Imports and activates immutable GST candidate-rate notification releases."

  import Ecto.Query, only: [from: 2]

  alias Nila.Gst.Rates.{Directory, Notification09, Release, Rule}
  alias Nila.Repo

  def import(path, opts \\ []) do
    with {:ok, bytes} <- File.read(path),
         hash = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower),
         {:error, :not_found} <- Repo.fetch_by(Release, file_sha256: hash),
         {:ok, parsed} <- Notification09.extract(path) do
      persist(path, hash, parsed, opts)
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

  defp persist(path, hash, parsed, opts) do
    now = DateTime.utc_now()
    metadata = parsed.metadata

    Repo.transact(fn ->
      release =
        %Release{}
        |> Release.changeset(%{
          notification_number: metadata.notification_number,
          tax_type: metadata.tax_type,
          source_name: Path.basename(path),
          source_url: Keyword.get(opts, :source_url),
          file_sha256: hash,
          published_on: metadata.published_on,
          effective_from: metadata.effective_from,
          observed_at: Keyword.get(opts, :observed_at, now)
        })
        |> Repo.insert!()

      parsed.rules
      |> Enum.map(fn rule ->
        rule
        |> Map.put(:release_id, release.id)
        |> Map.put(:inserted_at, now)
      end)
      |> Enum.chunk_every(1_000)
      |> Enum.each(&Repo.insert_all(Rule, &1))

      {:ok,
       %{
         release: release,
         rules: length(parsed.rules),
         automatic: Enum.count(parsed.rules, &(&1.parser_confidence == "automatic")),
         review: Enum.count(parsed.rules, &(&1.parser_confidence == "review"))
       }}
    end)
  end

  defp fetch_staged_for_update(release_id) do
    Repo.fetch_one(
      from r in Release,
        where: r.id == ^release_id and r.status == "staged",
        lock: "FOR UPDATE"
    )
  end
end
