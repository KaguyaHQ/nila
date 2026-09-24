defmodule Nila.Repo.Migrations.AddBusinessGoods do
  use Ecto.Migration

  def change do
    alter table(:business_services) do
      add :kind, :string, null: false, default: "service"
    end

    alter table(:business_profiles) do
      add :domestic_goods_and_services_only, :boolean, null: false, default: false
    end
  end
end
