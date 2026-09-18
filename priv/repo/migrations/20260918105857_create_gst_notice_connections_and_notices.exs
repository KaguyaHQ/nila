defmodule Nila.Repo.Migrations.CreateGstNoticeConnectionsAndNotices do
  use Ecto.Migration

  def change do
    create table(:gst_notice_connections) do
      add :client_id, references(:clients, on_delete: :delete_all), null: false
      add :gstin, :string, null: false
      add :username, :string, null: false
      add :credentials, :binary, null: false
      add :authorized_at, :utc_datetime_usec, null: false
      add :last_checked_at, :utc_datetime_usec
      add :last_error, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:gst_notice_connections, [:client_id])

    create table(:gst_notices) do
      add :client_id, references(:clients, on_delete: :delete_all), null: false
      add :gstin, :string, null: false
      add :reference, :string, null: false
      add :notice_type, :string
      add :issued_on, :date
      add :reply_due_on, :date
      add :payload, :map, null: false
      add :fetched_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:gst_notices, [:client_id, :gstin, :reference])
  end
end
