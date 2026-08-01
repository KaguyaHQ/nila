defmodule Nila.Repo.Migrations.CreateGstIntakeConfirmations do
  use Ecto.Migration

  def change do
    create table(:gst_intake_confirmations) do
      add :org_id, references(:orgs, on_delete: :delete_all), null: false
      add :client_id, references(:clients, on_delete: :delete_all), null: false
      add :period, :string, null: false
      add :decision, :string, null: false
      add :channel, :string, null: false
      add :source_ref, :string
      add :actor_phone, :string
      add :actor_user_id, references(:users, on_delete: :nilify_all)
      add :reason, :text

      timestamps(updated_at: false)
    end

    create index(:gst_intake_confirmations, [:org_id, :client_id, :period],
             name: :gst_intake_confirmations_tenancy_index
           )

    create index(:gst_intake_confirmations, [:actor_user_id])

    create unique_index(:gst_intake_confirmations, [:org_id, :channel, :source_ref],
             where: "source_ref IS NOT NULL",
             name: :gst_intake_confirmations_source_ref_index
           )
  end
end
