defmodule Nila.Repo.Migrations.AddFiledGstr1ToSalesMonths do
  use Ecto.Migration

  # The return the portal actually holds, uploaded as JSON for the workbench's
  # derived-vs-filed overlay. Nullable: most months never load one.
  def change do
    alter table(:sales_months) do
      add :filed_gstr1, :map
    end
  end
end
