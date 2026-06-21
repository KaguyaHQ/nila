defmodule Nila.Documents.Artifact do
  use Nila.Schema
  import Ecto.Changeset

  @statuses ~w(pending_review approved rejected superseded)

  schema "document_artifacts" do
    field :kind, :string
    field :version, :integer, default: 1
    field :data, :map, default: %{}
    field :status, :string, default: "pending_review"
    field :reviewed_at, :utc_datetime_usec

    belongs_to :document, Nila.Documents.Document
    belongs_to :reviewed_by, Nila.Accounts.User

    timestamps()
  end

  def changeset(artifact, attrs) do
    artifact
    |> cast(attrs, [:document_id, :kind, :version, :data, :status, :reviewed_by_id, :reviewed_at])
    |> validate_required([:document_id, :kind, :version, :data, :status])
    |> validate_number(:version, greater_than: 0)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:document_id, :kind, :version])
  end
end
