defmodule Nila.Repo.Migrations.IndexSalesInvoiceCorrectionsBySource do
  use Ecto.Migration

  def change do
    create index(:sales_invoice_corrections, [
             :org_id,
             :client_id,
             :source_id,
             :inserted_at
           ])
  end
end
