defmodule Nila.Documents do
  import Ecto.Query

  alias Nila.Documents.{Artifact, Document}
  alias Nila.Repo

  @doc """
  Lists an org's documents, newest first. Pass `document_type:` to filter in the
  query (e.g. `document_type: "purchase_order"`) instead of loading all and
  filtering in memory.
  """
  def list_documents(org_id, opts \\ []) do
    Document
    |> where([document], document.org_id == ^org_id)
    |> maybe_filter_document_type(Keyword.get(opts, :document_type))
    |> order_by([document], desc: document.inserted_at)
    |> preload([:uploaded_by, :artifacts])
    |> Repo.all()
  end

  defp maybe_filter_document_type(query, nil), do: query

  defp maybe_filter_document_type(query, type),
    do: where(query, [document], document.document_type == ^type)

  def get_document!(id) do
    Document
    |> Repo.get!(id)
    |> Repo.preload([:uploaded_by, :artifacts])
  end

  def create_document(attrs) do
    %Document{}
    |> Document.changeset(attrs)
    |> Repo.insert()
  end

  def update_document(%Document{} = document, attrs) do
    document
    |> Document.changeset(attrs)
    |> Repo.update()
  end

  def mark_processing(%Document{} = document) do
    update_document(document, %{status: "processing", processing_started_at: DateTime.utc_now()})
  end

  def mark_failed(%Document{} = document) do
    update_document(document, %{status: "failed"})
  end

  def create_artifact(attrs) do
    %Artifact{}
    |> Artifact.changeset(attrs)
    |> Repo.insert()
  end

  def create_or_update_artifact(attrs) do
    %Artifact{}
    |> Artifact.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:data, :status, :reviewed_by_id, :reviewed_at, :updated_at]},
      conflict_target: [:document_id, :kind, :version],
      returning: true
    )
  end

  def approve_artifact(%Artifact{} = artifact, reviewer_id) do
    artifact = Repo.preload(artifact, :document)
    reviewed_at = DateTime.utc_now()

    Repo.transact(fn ->
      with {:ok, approved_artifact} <-
             Repo.update(
               Artifact.changeset(artifact, %{
                 status: "approved",
                 reviewed_by_id: reviewer_id,
                 reviewed_at: reviewed_at
               })
             ),
           {:ok, _document} <-
             Repo.update(Document.changeset(artifact.document, %{status: "approved"})) do
        %{
          org_id: artifact.document.org_id,
          actor_id: reviewer_id,
          action: "#{artifact.kind}.approved",
          entity_type: "document_artifact",
          entity_id: approved_artifact.id,
          metadata: %{
            document_id: artifact.document_id,
            filename: artifact.document.filename
          }
        }
        |> audit_changeset()
        |> Repo.insert!()

        {:ok, approved_artifact}
      end
    end)
    |> case do
      {:ok, approved_artifact} -> {:ok, approved_artifact}
      {:error, reason} -> {:error, reason}
    end
  end

  def reject_artifact(%Artifact{} = artifact, reviewer_id) do
    artifact = Repo.preload(artifact, :document)
    reviewed_at = DateTime.utc_now()

    Repo.transact(fn ->
      with {:ok, rejected_artifact} <-
             Repo.update(
               Artifact.changeset(artifact, %{
                 status: "rejected",
                 reviewed_by_id: reviewer_id,
                 reviewed_at: reviewed_at
               })
             ),
           {:ok, _document} <-
             Repo.update(Document.changeset(artifact.document, %{status: "rejected"})) do
        %{
          org_id: artifact.document.org_id,
          actor_id: reviewer_id,
          action: "#{artifact.kind}.rejected",
          entity_type: "document_artifact",
          entity_id: rejected_artifact.id,
          metadata: %{
            document_id: artifact.document_id,
            filename: artifact.document.filename
          }
        }
        |> audit_changeset()
        |> Repo.insert!()

        {:ok, rejected_artifact}
      end
    end)
    |> case do
      {:ok, rejected_artifact} -> {:ok, rejected_artifact}
      {:error, reason} -> {:error, reason}
    end
  end

  def change_document(%Document{} = document, attrs \\ %{}) do
    Document.changeset(document, attrs)
  end

  defp audit_changeset(attrs) do
    %Nila.Audits.AuditLog{}
    |> Nila.Audits.AuditLog.changeset(attrs)
  end
end
