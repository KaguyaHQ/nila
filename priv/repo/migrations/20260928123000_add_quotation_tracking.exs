defmodule Nila.Repo.Migrations.AddQuotationTracking do
  use Ecto.Migration

  def change do
    alter table(:business_invoices) do
      add :sent_on, :date
    end
  end
end
