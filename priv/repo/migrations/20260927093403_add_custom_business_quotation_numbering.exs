defmodule Nila.Repo.Migrations.AddCustomBusinessQuotationNumbering do
  use Ecto.Migration

  def change do
    alter table(:business_profiles) do
      add :quotation_number_prefix, :string
      add :quotation_number_min_digits, :integer, null: false, default: 1
    end
  end
end
