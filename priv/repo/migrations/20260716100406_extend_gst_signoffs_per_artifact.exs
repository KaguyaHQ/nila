defmodule Nila.Repo.Migrations.ExtendGstSignoffsPerArtifact do
  use Ecto.Migration

  def change do
    alter table(:gst_signoffs) do
      add :artifact, :string, null: false, default: "gstr3b"
      add :sales_month_id, references(:sales_months, on_delete: :delete_all)
      add :revoked_at, :utc_datetime_usec
      add :revoked_by_id, references(:users)
    end

    execute "ALTER TABLE gst_signoffs ALTER COLUMN client_month_id DROP NOT NULL",
            "ALTER TABLE gst_signoffs ALTER COLUMN client_month_id SET NOT NULL"

    create index(:gst_signoffs, [:sales_month_id])

    create constraint(:gst_signoffs, :signoff_artifact_parent,
             check: """
             (artifact = 'gstr1' AND sales_month_id IS NOT NULL) OR \
             (artifact = 'gstr3b' AND client_month_id IS NOT NULL)
             """
           )
  end
end
