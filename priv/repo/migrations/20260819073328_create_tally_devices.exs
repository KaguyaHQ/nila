defmodule Nila.Repo.Migrations.CreateTallyDevices do
  use Ecto.Migration

  def change do
    create table(:tally_devices) do
      add :org_id, references(:orgs, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :token_hash, :binary, null: false
      add :last_connected_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:tally_devices, [:org_id])
    create unique_index(:tally_devices, [:token_hash])
  end
end
