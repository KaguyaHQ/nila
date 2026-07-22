defmodule Nila.Gst.Intake.ExtractionAttempt do
  use Nila.Schema

  @statuses ~w(running succeeded failed)

  schema "gst_extraction_attempts" do
    field :source_storage_key, :string
    field :provider, :string
    field :model, :string
    field :provider_request_id, :string
    field :worker_attempt, :integer
    field :status, :string, default: "running"
    field :http_status, :integer
    field :source_byte_size, :integer
    field :source_page_count, :integer
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :duration_ms, :integer
    field :usage, :map, default: %{}
    field :response_artifact_key, :string
    field :response_sha256, :string
    field :response_byte_size, :integer
    field :artifact_byte_size, :integer
    field :error, :string

    belongs_to :org, Nila.Orgs.Org
    belongs_to :dump, Nila.Gst.Intake.Dump, foreign_key: :gst_dump_id

    timestamps()
  end

  def changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [
      :provider_request_id,
      :status,
      :http_status,
      :source_page_count,
      :completed_at,
      :duration_ms,
      :usage,
      :response_artifact_key,
      :response_sha256,
      :response_byte_size,
      :artifact_byte_size,
      :error
    ])
    |> validate_required([
      :org_id,
      :gst_dump_id,
      :source_storage_key,
      :provider,
      :model,
      :worker_attempt,
      :status,
      :source_byte_size,
      :started_at
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:worker_attempt, greater_than: 0)
    |> validate_number(:source_byte_size, greater_than_or_equal_to: 0)
  end
end
