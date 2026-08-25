defmodule Nila.Repo.Migrations.CreateSalesInvoiceCorrections do
  use Ecto.Migration

  def up do
    create table(:sales_invoice_corrections) do
      add :org_id, references(:orgs, on_delete: :delete_all), null: false
      add :client_id, references(:clients, on_delete: :delete_all), null: false
      add :batch_ref, :string, null: false
      add :source_id, :string, null: false
      add :field_path, :string, null: false
      add :payload, :map, null: false
      add :corrected_by_id, references(:users, on_delete: :nilify_all)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:sales_invoice_corrections, [
             :org_id,
             :client_id,
             :batch_ref,
             :source_id,
             :inserted_at
           ])

    create index(:sales_invoice_corrections, [:corrected_by_id])
  end

  def down do
    drop_if_exists table(:sales_invoice_corrections)
  end
end
