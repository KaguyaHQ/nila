defmodule Nila.Repo.Migrations.CreateGstSignoffs do
  use Ecto.Migration

  def change do
    create table(:gst_signoffs) do
      add :client_month_id, references(:client_months, on_delete: :delete_all), null: false
      add :org_id, references(:orgs, on_delete: :delete_all), null: false
      add :signed_by_id, references(:users), null: false
      add :snapshot, :map, null: false

      timestamps(updated_at: false)
    end

    create index(:gst_signoffs, [:client_month_id])
    create index(:gst_signoffs, [:org_id])
  end
end
