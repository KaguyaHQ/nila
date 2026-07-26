defmodule Nila.Repo.Migrations.AddRequestMetadataToExtractionAttempts do
  use Ecto.Migration

  def change do
    alter table(:gst_extraction_attempts) do
      add :request_metadata, :map, null: false, default: %{}
    end
  end
end
