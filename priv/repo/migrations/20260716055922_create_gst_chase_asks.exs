defmodule Nila.Repo.Migrations.CreateGstChaseAsks do
  use Ecto.Migration

  def change do
    create table(:gst_chase_asks) do
      add :org_id, references(:orgs, on_delete: :delete_all), null: false
      add :client_id, references(:clients, on_delete: :delete_all), null: false
      add :period, :string, null: false
      add :kind, :string, null: false
      add :body, :text, null: false
      add :sent_by_id, references(:users), null: false

      timestamps(updated_at: false)
    end

    create index(:gst_chase_asks, [:org_id])
    create index(:gst_chase_asks, [:client_id, :period])
  end
end
