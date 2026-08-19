defmodule Nila.Repo.Migrations.CreateTallySyncStorage do
  use Ecto.Migration

  def change do
    create table(:tally_sync_runs) do
      add :org_id, references(:orgs, on_delete: :delete_all), null: false
      add :device_id, references(:tally_devices, on_delete: :delete_all), null: false
      add :company_id, references(:tally_companies, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "running"
      add :masters_status, :string, null: false, default: "pending"
      add :vouchers_status, :string, null: false, default: "pending"
      add :period_start, :date, null: false
      add :period_end, :date, null: false
      add :masters_count, :integer
      add :vouchers_count, :integer
      add :masters_error, :string
      add :vouchers_error, :string
      add :started_at, :utc_datetime_usec, null: false
      add :completed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:tally_sync_runs, [:org_id, :company_id, :inserted_at])
    create index(:tally_sync_runs, [:device_id, :status])

    create table(:tally_synced_masters) do
      add :org_id, references(:orgs, on_delete: :delete_all), null: false
      add :company_id, references(:tally_companies, on_delete: :delete_all), null: false
      add :last_seen_sync_id, references(:tally_sync_runs, on_delete: :nilify_all)
      add :kind, :string, null: false
      add :identity, :string, null: false
      add :name, :string, null: false
      add :tally_guid, :string
      add :alter_id, :string
      add :data, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tally_synced_masters, [:company_id, :kind, :identity])
    create index(:tally_synced_masters, [:org_id, :company_id])

    create table(:tally_synced_vouchers) do
      add :org_id, references(:orgs, on_delete: :delete_all), null: false
      add :company_id, references(:tally_companies, on_delete: :delete_all), null: false
      add :last_seen_sync_id, references(:tally_sync_runs, on_delete: :nilify_all)
      add :identity, :string, null: false
      add :master_id, :bigint
      add :tally_guid, :string
      add :remote_id, :string
      add :date, :date, null: false
      add :voucher_type, :string, null: false
      add :voucher_number, :string
      add :narration, :text
      add :data, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tally_synced_vouchers, [:company_id, :identity])
    create index(:tally_synced_vouchers, [:org_id, :company_id, :date])
  end
end
