defmodule Nila.Repo.Migrations.AddSalesCessEvaluation do
  use Ecto.Migration

  def change do
    alter table(:sales_months) do
      add :cess_evaluated, :boolean, null: false, default: false
    end
  end
end
