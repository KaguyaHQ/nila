defmodule Nila.Repo.Migrations.CreateTallySalesLineMappings do
  use Ecto.Migration

  def up do
    create table(:tally_sales_line_mappings) do
      add :org_id, references(:orgs, on_delete: :delete_all), null: false
      add :company_id, references(:tally_companies, on_delete: :delete_all), null: false
      add :source_key, :string, null: false
      add :hsn_sac, :string
      add :normalized_description, :string, null: false
      add :ledger_identity, :string, null: false
      add :confirmed_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tally_sales_line_mappings, [:company_id, :source_key])
    create index(:tally_sales_line_mappings, [:org_id, :company_id])
    create index(:tally_sales_line_mappings, [:company_id, :ledger_identity])
  end

  def down do
    drop_if_exists table(:tally_sales_line_mappings)
  end
end
