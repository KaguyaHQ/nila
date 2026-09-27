defmodule Nila.Repo.Migrations.AllowMultipleBusinessClientAccesses do
  use Ecto.Migration

  def change do
    drop_if_exists unique_index(:business_client_accesses, [:user_id])
    create unique_index(:business_client_accesses, [:user_id, :client_id])
  end
end
