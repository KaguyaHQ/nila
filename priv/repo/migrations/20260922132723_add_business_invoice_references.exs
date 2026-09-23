defmodule Nila.Repo.Migrations.AddBusinessInvoiceReferences do
  use Ecto.Migration

  def change do
    alter table(:business_invoices) do
      add :purchase_order_number, :string
      add :purchase_order_date, :date
      add :delivery_address, :text
    end
  end
end
