defmodule Nila.Repo.Migrations.AddCompletenessAsksAndIntakeMessages do
  use Ecto.Migration

  def change do
    alter table(:gst_chase_asks) do
      add :ask_ref, :uuid
      add :provider_ref, :string
    end

    create unique_index(:gst_chase_asks, [:org_id, :ask_ref],
             where: "ask_ref IS NOT NULL",
             name: :gst_chase_asks_ask_ref_index
           )

    create index(:gst_chase_asks, [:org_id, :provider_ref],
             where: "provider_ref IS NOT NULL",
             name: :gst_chase_asks_provider_ref_index
           )

    create table(:gst_intake_messages) do
      add :org_id, references(:orgs, on_delete: :delete_all), null: false
      add :client_id, references(:clients, on_delete: :nilify_all)
      add :chase_ask_id, references(:gst_chase_asks, on_delete: :nilify_all)
      add :period, :string
      add :channel, :string, null: false
      add :source_ref, :string, null: false
      add :provider_context_ref, :string
      add :sender, :string, null: false
      add :body, :text, null: false
      add :received_at, :utc_datetime_usec, null: false

      timestamps(updated_at: false)
    end

    create unique_index(:gst_intake_messages, [:org_id, :channel, :source_ref],
             name: :gst_intake_messages_source_ref_index
           )

    create index(:gst_intake_messages, [:org_id, :client_id, :period],
             name: :gst_intake_messages_tenancy_index
           )
  end
end
