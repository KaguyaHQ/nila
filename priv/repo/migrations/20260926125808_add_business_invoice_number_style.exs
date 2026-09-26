defmodule Nila.Repo.Migrations.AddBusinessInvoiceNumberStyle do
  use Ecto.Migration

  def change do
    alter table(:business_profiles) do
      add :invoice_number_style, :string, default: "nila", null: false
    end
  end
end
