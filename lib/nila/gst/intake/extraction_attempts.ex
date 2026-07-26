defmodule Nila.Gst.Intake.ExtractionAttempts do
  import Ecto.Query, only: [from: 2]

  alias Nila.Gst.Intake.{Dump, ExtractionAttempt}
  alias Nila.{Repo, Storage}

  def start(%Dump{} = dump, attrs) do
    %ExtractionAttempt{
      org_id: dump.org_id,
      gst_dump_id: dump.id,
      source_storage_key: Map.fetch!(attrs, :source_storage_key),
      provider: Map.fetch!(attrs, :provider),
      model: Map.fetch!(attrs, :model),
      worker_attempt: Map.fetch!(attrs, :worker_attempt),
      source_byte_size: Map.fetch!(attrs, :source_byte_size),
      started_at: Map.fetch!(attrs, :started_at),
      request_metadata: Map.get(attrs, :request_metadata) || %{}
    }
    |> ExtractionAttempt.changeset(%{})
    |> Repo.insert()
  end

  def succeed(%ExtractionAttempt{} = attempt, attrs) do
    complete(attempt, "succeeded", attrs)
  end

  def fail(%ExtractionAttempt{} = attempt, attrs) do
    complete(attempt, "failed", attrs)
  end

  def list_for_dump(dump_id) do
    Repo.all(
      from a in ExtractionAttempt,
        where: a.gst_dump_id == ^dump_id,
        order_by: [asc: a.inserted_at, asc: a.id]
    )
  end

  defp complete(attempt, status, attrs) do
    {raw_response, attrs} = Map.pop(attrs, :raw_response)

    case store_response(attempt, raw_response) do
      {:ok, artifact_attrs} ->
        changes =
          attrs
          |> Map.merge(artifact_attrs)
          |> Map.put(:status, status)
          |> Map.put_new(:completed_at, DateTime.utc_now())

        case attempt |> ExtractionAttempt.changeset(changes) |> Repo.update() do
          {:ok, completed} ->
            {:ok, completed}

          {:error, %Ecto.Changeset{} = changeset} = error ->
            delete_artifact(changeset)
            error
        end

      {:error, reason} ->
        attempt
        |> ExtractionAttempt.changeset(%{
          status: "failed",
          completed_at: DateTime.utc_now(),
          error: inspect(reason)
        })
        |> Repo.update()

        {:error, reason}
    end
  end

  defp store_response(_attempt, nil), do: {:ok, %{}}

  defp store_response(attempt, raw_response) when is_binary(raw_response) do
    compressed = IO.iodata_to_binary(:zstd.compress(raw_response))
    sha256 = Base.encode16(:crypto.hash(:sha256, raw_response), case: :lower)
    key = artifact_key(attempt)

    case Storage.put(key, compressed, content_type: "application/zstd") do
      {:ok, _stored} ->
        {:ok,
         %{
           response_artifact_key: key,
           response_sha256: sha256,
           response_byte_size: byte_size(raw_response),
           artifact_byte_size: byte_size(compressed)
         }}

      {:error, reason} ->
        {:error, {:raw_response_storage_failed, reason}}
    end
  end

  defp artifact_key(attempt) do
    "orgs/#{attempt.org_id}/gst/dumps/#{attempt.gst_dump_id}/extraction_attempts/#{attempt.id}/raw_response.json.zst"
  end

  defp delete_artifact(%Ecto.Changeset{changes: %{response_artifact_key: key}}) do
    Storage.delete(key)
  end

  defp delete_artifact(_changeset), do: :ok
end
