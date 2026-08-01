defmodule Nila.Repo.Migrations.CreateHsnMaster do
  use Ecto.Migration

  def change do
    create table(:hsn_master_releases) do
      add :source_name, :string, null: false
      add :source_url, :text
      add :file_sha256, :string, null: false
      add :status, :string, null: false, default: "staged"
      add :observed_at, :utc_datetime_usec, null: false
      add :activated_at, :utc_datetime_usec

      timestamps(updated_at: false)
    end

    create unique_index(:hsn_master_releases, [:file_sha256])

    create unique_index(:hsn_master_releases, [:status],
             where: "status = 'active'",
             name: :hsn_master_releases_one_active_index
           )

    create constraint(:hsn_master_releases, :hsn_master_releases_status_check,
             check: "status IN ('staged', 'active', 'superseded')"
           )

    create table(:hsn_master_entries) do
      add :release_id, references(:hsn_master_releases, on_delete: :delete_all), null: false
      add :code, :string, null: false
      add :description, :text, null: false
      add :kind, :string, null: false
      add :digits, :integer, null: false
      add :parent_code, :string
      add :has_children, :boolean, null: false, default: false

      timestamps(updated_at: false)
    end

    create unique_index(:hsn_master_entries, [:release_id, :kind, :code])
    create index(:hsn_master_entries, [:release_id, :code])

    create constraint(:hsn_master_entries, :hsn_master_entries_kind_check,
             check: "kind IN ('hsn', 'sac')"
           )

    alter table(:sales_months) do
      add :hsn_master_release_id,
          references(:hsn_master_releases, on_delete: :nilify_all)
    end

    alter table(:client_months) do
      add :hsn_master_release_id,
          references(:hsn_master_releases, on_delete: :nilify_all)
    end

    create index(:sales_months, [:hsn_master_release_id])
    create index(:client_months, [:hsn_master_release_id])
  end
end
