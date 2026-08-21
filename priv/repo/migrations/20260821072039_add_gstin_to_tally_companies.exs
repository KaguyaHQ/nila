defmodule Nila.Repo.Migrations.AddGstinToTallyCompanies do
  use Ecto.Migration

  def change do
    alter table(:tally_companies) do
      add :gstin, :string
    end
  end
end
