defmodule Nila.Repo.Migrations.CreateClientMonths do
  use Ecto.Migration

  def change do
    create table(:client_months) do
      add :org_id, references(:orgs, on_delete: :delete_all), null: false
      add :client_id, references(:clients, on_delete: :delete_all), null: false
      add :period, :string, null: false
      add :state, :string, null: false, default: "worked"
      add :register_rows, {:array, :map}, null: false, default: []
      add :recon, :map, null: false, default: %{}
      add :summary, :map, null: false, default: %{}

      timestamps()
    end

    create index(:client_months, [:org_id])
    create unique_index(:client_months, [:client_id, :period])
  end
end
