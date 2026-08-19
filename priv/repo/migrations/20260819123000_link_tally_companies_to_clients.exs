defmodule Nila.Repo.Migrations.LinkTallyCompaniesToClients do
  use Ecto.Migration

  def change do
    alter table(:tally_companies) do
      add :client_id, references(:clients, on_delete: :nilify_all)
    end

    create index(:tally_companies, [:client_id])
  end
end
