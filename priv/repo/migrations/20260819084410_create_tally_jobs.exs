defmodule Nila.Repo.Migrations.CreateTallyJobs do
  use Ecto.Migration

  def change do
    create table(:tally_jobs) do
      add :org_id, references(:orgs, on_delete: :delete_all), null: false
      add :device_id, references(:tally_devices, on_delete: :delete_all), null: false
      add :job_key, :uuid, null: false
      add :kind, :string, null: false
      add :payload, :map, null: false
      add :status, :string, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :result, :map
      add :error, :map

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tally_jobs, [:org_id, :job_key])
    create index(:tally_jobs, [:device_id, :status, :id])

    create constraint(:tally_jobs, :valid_status,
             check: "status IN ('pending', 'running', 'succeeded', 'failed')"
           )
  end
end
