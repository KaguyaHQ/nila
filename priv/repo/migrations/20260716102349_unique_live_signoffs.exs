defmodule Nila.Repo.Migrations.UniqueLiveSignoffs do
  use Ecto.Migration

  def change do
    create unique_index(:gst_signoffs, [:sales_month_id],
             where: "artifact = 'gstr1' AND revoked_at IS NULL",
             name: :gst_signoffs_live_gstr1_index
           )

    create unique_index(:gst_signoffs, [:client_month_id],
             where: "artifact = 'gstr3b' AND revoked_at IS NULL",
             name: :gst_signoffs_live_gstr3b_index
           )

    execute "ALTER TABLE gst_signoffs DROP CONSTRAINT signoff_artifact_parent",
            "ALTER TABLE gst_signoffs ADD CONSTRAINT signoff_artifact_parent CHECK ((artifact = 'gstr1' AND sales_month_id IS NOT NULL) OR (artifact = 'gstr3b' AND client_month_id IS NOT NULL))"

    execute "ALTER TABLE gst_signoffs ADD CONSTRAINT signoff_artifact_parent CHECK ((artifact = 'gstr1' AND sales_month_id IS NOT NULL AND client_month_id IS NULL) OR (artifact = 'gstr3b' AND client_month_id IS NOT NULL AND sales_month_id IS NULL))",
            "ALTER TABLE gst_signoffs DROP CONSTRAINT signoff_artifact_parent"
  end
end
