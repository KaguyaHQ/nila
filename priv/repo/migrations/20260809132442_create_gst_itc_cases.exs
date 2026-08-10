defmodule Nila.Repo.Migrations.CreateGstItcCases do
  use Ecto.Migration

  def change do
    create table(:gst_itc_cases) do
      add :org_id, references(:orgs, on_delete: :delete_all), null: false
      add :client_id, references(:clients, on_delete: :delete_all), null: false
      add :supplier_gstin, :string
      add :document_type, :string, null: false, default: "invoice"
      add :invoice_number, :string
      add :normalized_invoice_number, :string
      add :supplier_fy_start_year, :integer
      add :match_key, :string
      add :identity_state, :string, null: false, default: "provisional"
      add :merged_into_case_id, references(:gst_itc_cases, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:gst_itc_cases, [:org_id, :client_id])
    create index(:gst_itc_cases, [:client_id, :match_key])
    create index(:gst_itc_cases, [:merged_into_case_id])

    create constraint(:gst_itc_cases, :gst_itc_cases_identity_state,
             check: "identity_state IN ('provisional', 'confirmed', 'ambiguous', 'merged')"
           )

    create table(:gst_itc_sources) do
      add :client_month_id, references(:client_months, on_delete: :delete_all), null: false
      add :org_id, references(:orgs, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :source_ref, :string, null: false
      add :payload, :map, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:gst_itc_sources, [:client_month_id, :kind, :source_ref])
    create index(:gst_itc_sources, [:org_id])

    create constraint(:gst_itc_sources, :gst_itc_sources_kind,
             check: "kind IN ('books', 'gstr2b')"
           )

    create table(:gst_itc_source_case_events) do
      add :source_id, references(:gst_itc_sources, on_delete: :delete_all), null: false
      add :case_id, references(:gst_itc_cases, on_delete: :delete_all), null: false

      add :effective_client_month_id, references(:client_months, on_delete: :restrict),
        null: false

      add :org_id, references(:orgs, on_delete: :delete_all), null: false
      add :action, :string, null: false
      add :reason, :string, null: false
      add :decided_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:gst_itc_source_case_events, [:source_id, :id])
    create index(:gst_itc_source_case_events, [:case_id, :id])
    create index(:gst_itc_source_case_events, [:effective_client_month_id])
    create index(:gst_itc_source_case_events, [:org_id])

    create constraint(:gst_itc_source_case_events, :gst_itc_source_case_events_action,
             check: "action IN ('linked', 'unlinked')"
           )

    create table(:gst_itc_case_events) do
      add :case_id, references(:gst_itc_cases, on_delete: :delete_all), null: false

      add :effective_client_month_id, references(:client_months, on_delete: :restrict),
        null: false

      add :org_id, references(:orgs, on_delete: :delete_all), null: false
      add :event_type, :string, null: false
      add :payload, :map, null: false, default: %{}
      add :decided_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:gst_itc_case_events, [:case_id, :inserted_at])
    create index(:gst_itc_case_events, [:effective_client_month_id])
    create index(:gst_itc_case_events, [:org_id])

    create table(:gst_itc_allocations) do
      add :case_id, references(:gst_itc_cases, on_delete: :restrict), null: false
      add :client_month_id, references(:client_months, on_delete: :restrict), null: false
      add :signoff_id, references(:gst_signoffs, on_delete: :restrict), null: false
      add :org_id, references(:orgs, on_delete: :delete_all), null: false
      add :kind, :string, null: false, default: "original_claim"
      add :tax_heads, :map, null: false
      add :tax_paise, :bigint, null: false
      add :filed_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:gst_itc_allocations, [:client_month_id])
    create index(:gst_itc_allocations, [:signoff_id])
    create index(:gst_itc_allocations, [:org_id])

    create unique_index(:gst_itc_allocations, [:case_id, :kind],
             where: "revoked_at IS NULL",
             name: :gst_itc_allocations_live_entitlement_index
           )

    create constraint(:gst_itc_allocations, :gst_itc_allocations_kind,
             check: "kind = 'original_claim'"
           )

    create constraint(:gst_itc_allocations, :gst_itc_allocations_terminal_state,
             check: "NOT (filed_at IS NOT NULL AND revoked_at IS NOT NULL)"
           )
  end
end
