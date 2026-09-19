defmodule Nila.Repo.Migrations.CreateGstPortalStatements do
  use Ecto.Migration

  def change do
    create table(:gst_portal_statements) do
      add :client_id, references(:clients, on_delete: :delete_all), null: false
      add :gstin, :string, null: false
      add :period, :string, null: false
      add :document, :map
      add :fetched_at, :utc_datetime_usec
      add :status, :string, null: false, default: "pending"
      add :last_error, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:gst_portal_statements, [:client_id, :gstin, :period])
  end
end
