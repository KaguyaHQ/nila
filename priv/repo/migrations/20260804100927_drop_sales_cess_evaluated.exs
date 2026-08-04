defmodule Nila.Repo.Migrations.DropSalesCessEvaluated do
  use Ecto.Migration

  def change do
    alter table(:sales_months) do
      remove :cess_evaluated, :boolean, null: false, default: false
    end
  end
end
