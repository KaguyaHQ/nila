defmodule Nila.Repo.Migrations.CreateGstArrivals do
  use Ecto.Migration

  def change do
    create table(:gst_arrivals) do
      add :org_id, references(:orgs, on_delete: :delete_all), null: false
      add :client_id, references(:clients, on_delete: :nilify_all)
      add :source, :string, null: false
      add :source_ref, :string
      add :sender, :string, null: false
      add :storage_key, :string, null: false
      add :filename, :string, null: false
      add :content_type, :string, null: false
      add :received_at, :utc_datetime_usec, null: false
      add :status, :string, null: false, default: "pending"
      add :routed_dump_id, references(:gst_dumps, on_delete: :nilify_all)

      timestamps()
    end

    create index(:gst_arrivals, [:org_id, :status])
    create unique_index(:gst_arrivals, [:org_id, :source, :source_ref])
    create index(:gst_arrivals, [:client_id])
    create index(:gst_arrivals, [:routed_dump_id])
  end
end
