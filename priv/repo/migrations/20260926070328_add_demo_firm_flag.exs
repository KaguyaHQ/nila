defmodule Nila.Repo.Migrations.AddDemoFirmFlag do
  use Ecto.Migration

  def change do
    alter table(:orgs) do
      add :is_demo, :boolean, default: false, null: false
    end
  end
end
