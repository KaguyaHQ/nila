defmodule Nila.Repo.Migrations.EnsureBusinessClientAccesses do
  use Ecto.Migration

  def up do
    create_if_not_exists table(:business_client_accesses) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :client_id, references(:clients, on_delete: :delete_all), null: false
      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists unique_index(:business_client_accesses, [:user_id])
    create_if_not_exists index(:business_client_accesses, [:client_id])
  end

  # The original creation migration owns removal of this table.
  def down, do: :ok
end
