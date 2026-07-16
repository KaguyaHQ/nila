defmodule Nila.Repo.Migrations.CreateSalesMonths do
  use Ecto.Migration

  def change do
    create table(:sales_months) do
      add :org_id, references(:orgs, on_delete: :delete_all), null: false
      add :client_id, references(:clients, on_delete: :delete_all), null: false
      add :period, :string, null: false
      add :state, :string, null: false, default: "worked"
      add :invoices, {:array, :map}, null: false, default: []
      add :derived_gstr1, :map, null: false, default: %{}
      add :issues, {:array, :map}, null: false, default: []
      add :summary, :map, null: false, default: %{}

      timestamps()
    end

    create index(:sales_months, [:org_id])
    create unique_index(:sales_months, [:client_id, :period])
  end
end
