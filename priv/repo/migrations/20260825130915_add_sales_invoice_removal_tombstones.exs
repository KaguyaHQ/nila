defmodule Nila.Repo.Migrations.AddSalesInvoiceRemovalTombstones do
  use Ecto.Migration

  def change do
    create_if_not_exists table(:sales_invoice_removals) do
      add :org_id, references(:orgs, on_delete: :delete_all), null: false
      add :client_id, references(:clients, on_delete: :delete_all), null: false
      add :batch_ref, :string, null: false
      add :source_id, :string, null: false
      add :removed_by_id, references(:users, on_delete: :nilify_all)
      add :removed_at, :utc_datetime_usec, null: false
    end

    create_if_not_exists unique_index(
                           :sales_invoice_removals,
                           [:org_id, :client_id, :batch_ref, :source_id]
                         )

    create_if_not_exists index(:sales_invoice_removals, [:removed_by_id])
  end
end
