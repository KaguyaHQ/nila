defmodule Nila.Repo.Migrations.CreateGstResolutions do
  use Ecto.Migration

  def change do
    create table(:gst_resolutions) do
      add :client_month_id, references(:client_months, on_delete: :delete_all), null: false
      add :org_id, references(:orgs, on_delete: :delete_all), null: false
      add :verb, :string, null: false
      add :books_id, :string
      add :gstr2b_ref, :string
      add :payload, :map, null: false, default: %{}
      add :decided_by_id, references(:users, on_delete: :nilify_all)

      timestamps(updated_at: false)
    end

    create index(:gst_resolutions, [:client_month_id])
    create index(:gst_resolutions, [:org_id])
  end
end
