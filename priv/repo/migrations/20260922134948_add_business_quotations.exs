defmodule Nila.Repo.Migrations.AddBusinessQuotations do
  use Ecto.Migration

  def change do
    alter table(:business_invoices) do
      add :valid_until, :date
      add :converted_invoice_id, references(:business_invoices, on_delete: :restrict)
    end

    create unique_index(:business_invoices, [:converted_invoice_id])
  end
end
