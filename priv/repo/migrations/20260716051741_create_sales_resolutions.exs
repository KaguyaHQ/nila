defmodule Nila.Repo.Migrations.CreateSalesResolutions do
  use Ecto.Migration

  def change do
    create table(:sales_resolutions) do
      add :sales_month_id, references(:sales_months, on_delete: :delete_all), null: false
      add :org_id, references(:orgs, on_delete: :delete_all), null: false
      add :verb, :string, null: false
      add :target, :string, null: false
      add :payload, :map, null: false, default: %{}
      add :decided_by_id, references(:users, on_delete: :nilify_all)

      timestamps(updated_at: false)
    end

    create index(:sales_resolutions, [:sales_month_id])
    create index(:sales_resolutions, [:org_id])
  end
end
