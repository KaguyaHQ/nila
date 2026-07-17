defmodule Nila.Repo.Migrations.CreateGstDumps do
  use Ecto.Migration

  def change do
    create table(:gst_dumps) do
      add :org_id, references(:orgs, on_delete: :delete_all), null: false
      add :client_id, references(:clients, on_delete: :delete_all), null: false
      add :period, :string, null: false
      add :kind, :string, null: false
      add :status, :string, null: false, default: "received"
      add :file_keys, {:array, :string}, null: false, default: []
      add :invoices, {:array, :map}, null: false, default: []
      add :meta, :map, null: false, default: %{}
      add :error, :string
      add :brought_in_by_id, references(:users)

      timestamps()
    end

    create index(:gst_dumps, [:org_id, :client_id, :period])
  end
end
