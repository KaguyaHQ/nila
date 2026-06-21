defmodule Nila.Documents.Document do
  use Nila.Schema
  import Ecto.Changeset

  @statuses ~w(uploaded processing needs_review approved rejected failed archived)

  def statuses, do: @statuses

  schema "documents" do
    field :storage_key, :string
    field :filename, :string
    field :content_type, :string
    field :byte_size, :integer
    field :sha256, :string
    field :document_type, :string
    field :status, :string, default: "uploaded"
    field :processing_started_at, :utc_datetime_usec
    field :extracted_at, :utc_datetime_usec

    belongs_to :org, Nila.Orgs.Org
    belongs_to :uploaded_by, Nila.Accounts.User
    has_many :artifacts, Nila.Documents.Artifact

    timestamps()
  end

  def changeset(document, attrs) do
    document
    |> cast(attrs, [
      :org_id,
      :uploaded_by_id,
      :storage_key,
      :filename,
      :content_type,
      :byte_size,
      :sha256,
      :document_type,
      :status,
      :processing_started_at,
      :extracted_at
    ])
    |> validate_required([:org_id, :storage_key, :filename, :byte_size, :status])
    |> validate_number(:byte_size, greater_than_or_equal_to: 0)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:org_id, :sha256])
  end
end
