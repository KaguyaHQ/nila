defmodule Nila.Repo.Migrations.CreateBusinessClientAccesses do
  use Ecto.Migration

  def change do
    create table(:business_client_accesses) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :client_id, references(:clients, on_delete: :delete_all), null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:business_client_accesses, [:user_id])
    create index(:business_client_accesses, [:client_id])
  end
end
