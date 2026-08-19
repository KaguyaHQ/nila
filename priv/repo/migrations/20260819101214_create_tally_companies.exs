defmodule Nila.Repo.Migrations.CreateTallyCompanies do
  use Ecto.Migration

  def change do
    create table(:tally_companies) do
      add :org_id, references(:orgs, on_delete: :delete_all), null: false
      add :device_id, references(:tally_devices, on_delete: :delete_all), null: false
      add :identity, :string, null: false
      add :name, :string, null: false
      add :tally_guid, :string
      add :is_open, :boolean, null: false, default: false
      add :last_seen_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:tally_companies, [:org_id, :is_open])
    create index(:tally_companies, [:device_id])
    create unique_index(:tally_companies, [:device_id, :identity])

    alter table(:tally_jobs) do
      add :source_key, :string
    end

    create unique_index(:tally_jobs, [:org_id, :source_key], where: "source_key IS NOT NULL")
  end
end
