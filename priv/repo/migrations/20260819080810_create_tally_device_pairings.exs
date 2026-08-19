defmodule Nila.Repo.Migrations.CreateTallyDevicePairings do
  use Ecto.Migration

  def change do
    create table(:tally_device_pairings) do
      add :device_code_hash, :binary, null: false
      add :approval_code_hash, :binary, null: false
      add :device_name, :string, null: false
      add :connector_version, :string
      add :expires_at, :utc_datetime_usec, null: false
      add :approved_at, :utc_datetime_usec
      add :exchanged_at, :utc_datetime_usec
      add :org_id, references(:orgs, on_delete: :delete_all)
      add :approved_by_user_id, references(:users, on_delete: :nilify_all)
      add :device_id, references(:tally_devices, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tally_device_pairings, [:device_code_hash])
    create unique_index(:tally_device_pairings, [:approval_code_hash])
    create unique_index(:tally_device_pairings, [:device_id], where: "device_id IS NOT NULL")
    create index(:tally_device_pairings, [:expires_at])
    create index(:tally_device_pairings, [:org_id])
  end
end
