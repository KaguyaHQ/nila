defmodule Nila.Repo.Migrations.ShareGstPortalConnectionsAndCacheTaxpayers do
  use Ecto.Migration

  def change do
    rename table(:gst_notice_connections), to: table(:gst_portal_connections)

    create table(:gst_notice_checks) do
      add :client_id, references(:clients, on_delete: :delete_all), null: false
      add :gstin, :string, null: false
      add :last_checked_at, :utc_datetime_usec
      add :last_error, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:gst_notice_checks, [:client_id, :gstin])

    execute(
      """
      INSERT INTO gst_notice_checks (client_id, gstin, last_checked_at, last_error, inserted_at, updated_at)
      SELECT client_id, gstin, last_checked_at, last_error, inserted_at, updated_at
      FROM gst_portal_connections
      """,
      """
      UPDATE gst_portal_connections AS c
      SET last_checked_at = n.last_checked_at, last_error = n.last_error
      FROM gst_notice_checks AS n WHERE c.client_id = n.client_id AND c.gstin = n.gstin
      """
    )

    alter table(:gst_portal_connections) do
      remove :last_checked_at, :utc_datetime_usec
      remove :last_error, :string
    end

    create table(:gst_taxpayer_lookups) do
      add :gstin, :string, null: false
      add :legal_name, :string, null: false
      add :trade_name, :string
      add :registration_status, :string, null: false
      add :provider, :string, null: false
      add :payload, :map, null: false
      add :checked_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:gst_taxpayer_lookups, [:gstin])
  end
end
