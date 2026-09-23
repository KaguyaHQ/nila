defmodule Nila.Repo.Migrations.CreateBusinessServices do
  use Ecto.Migration

  def change do
    create table(:business_services) do
      add :client_id, references(:clients, on_delete: :restrict), null: false
      add :description, :text, null: false
      add :sac, :string, null: false
      add :unit, :string, null: false, default: "service"
      add :unit_price, :decimal, precision: 14, scale: 2, null: false
      add :gst_rate, :decimal, precision: 5, scale: 3, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:business_services, [:client_id])
  end
end
