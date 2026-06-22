defmodule Nila.Repo.Migrations.CreateClients do
  use Ecto.Migration

  def change do
    create table(:clients) do
      add :org_id, references(:orgs, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :type, :string, null: false
      add :address, :text
      add :pan, :string
      add :gstin, :string
      add :phone, :string
      add :match_hints, {:array, :string}, null: false, default: []

      timestamps()
    end

    create index(:clients, [:org_id])
    create unique_index(:clients, [:org_id, :name])

    alter table(:bank_transactions) do
      add :client_id, references(:clients, on_delete: :nilify_all)
    end

    create index(:bank_transactions, [:client_id])
  end
end
