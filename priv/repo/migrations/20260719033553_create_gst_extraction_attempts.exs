defmodule Nila.Repo.Migrations.CreateGstExtractionAttempts do
  use Ecto.Migration

  def change do
    create table(:gst_extraction_attempts) do
      add :org_id, references(:orgs, on_delete: :delete_all), null: false
      add :gst_dump_id, references(:gst_dumps, on_delete: :delete_all), null: false
      add :source_storage_key, :string, null: false
      add :provider, :string, null: false
      add :model, :string, null: false
      add :provider_request_id, :string
      add :worker_attempt, :integer, null: false
      add :status, :string, null: false, default: "running"
      add :http_status, :integer
      add :source_byte_size, :bigint, null: false
      add :source_page_count, :integer
      add :started_at, :utc_datetime_usec, null: false
      add :completed_at, :utc_datetime_usec
      add :duration_ms, :bigint
      add :usage, :map, null: false, default: %{}
      add :response_artifact_key, :string
      add :response_sha256, :string
      add :response_byte_size, :bigint
      add :artifact_byte_size, :bigint
      add :error, :text

      timestamps()
    end

    create index(:gst_extraction_attempts, [:gst_dump_id, :inserted_at])
    create index(:gst_extraction_attempts, [:org_id, :status])
    create index(:gst_extraction_attempts, [:provider, :provider_request_id])
  end
end
