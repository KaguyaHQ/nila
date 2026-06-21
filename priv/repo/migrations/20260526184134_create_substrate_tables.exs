defmodule Nila.Repo.Migrations.CreateSubstrateTables do
  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS citext", "DROP EXTENSION IF EXISTS citext"

    create table(:users) do
      add :email, :citext, null: false
      add :name, :string, null: false
      add :active, :boolean, null: false, default: true
      add :hashed_password, :string
      add :confirmed_at, :utc_datetime_usec

      timestamps()
    end

    create unique_index(:users, [:email])

    create table(:users_tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token, :binary, null: false
      add :context, :string, null: false
      add :sent_to, :string

      timestamps(updated_at: false)
    end

    create index(:users_tokens, [:user_id])
    create unique_index(:users_tokens, [:context, :token])
    create index(:users_tokens, [:user_id, :context])

    create table(:orgs) do
      add :name, :string, null: false
      add :legal_name, :string
      add :gstin, :string
      add :status, :string, null: false, default: "active"

      timestamps()
    end

    create unique_index(:orgs, [:gstin], where: "gstin IS NOT NULL")

    create table(:org_entities) do
      add :org_id, references(:orgs, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :gstin, :string
      add :address_line1, :string
      add :address_line2, :string
      add :city, :string
      add :state, :string
      add :postal_code, :string
      add :country, :string, null: false, default: "India"
      add :contact_email, :citext
      add :contact_phone, :string
      add :bank_account_holder, :string
      add :bank_account_number, :binary
      add :bank_ifsc, :string
      add :bank_name, :string
      add :invoice_prefix, :string, null: false, default: ""
      add :invoice_next, :integer, null: false, default: 1
      add :invoice_padding, :integer, null: false, default: 0
      add :fiscal_year_start_month, :integer, null: false, default: 4

      timestamps()
    end

    create index(:org_entities, [:org_id])
    create unique_index(:org_entities, [:gstin], where: "gstin IS NOT NULL")
    create unique_index(:org_entities, [:org_id, :name])

    create table(:org_memberships) do
      add :role, :string, null: false, default: "member"
      add :org_id, references(:orgs, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps()
    end

    create unique_index(:org_memberships, [:org_id, :user_id])
    create index(:org_memberships, [:user_id])

    create table(:documents) do
      add :org_id, references(:orgs, on_delete: :delete_all), null: false
      add :uploaded_by_id, references(:users, on_delete: :nilify_all)
      add :storage_key, :string, null: false
      add :filename, :string, null: false
      add :content_type, :string
      add :byte_size, :bigint, null: false
      add :sha256, :string
      add :document_type, :string
      add :status, :string, null: false, default: "uploaded"
      add :processing_started_at, :utc_datetime_usec
      add :extracted_at, :utc_datetime_usec

      timestamps()
    end

    create index(:documents, [:org_id, :status])
    create index(:documents, [:uploaded_by_id])
    create unique_index(:documents, [:org_id, :sha256], where: "sha256 IS NOT NULL")

    create table(:document_artifacts) do
      add :document_id, references(:documents, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :version, :integer, null: false, default: 1
      add :data, :map, null: false, default: %{}
      add :status, :string, null: false, default: "pending_review"
      add :reviewed_by_id, references(:users, on_delete: :nilify_all)
      add :reviewed_at, :utc_datetime_usec

      timestamps()
    end

    create index(:document_artifacts, [:document_id])
    create unique_index(:document_artifacts, [:document_id, :kind, :version])

    create table(:workflow_runs) do
      add :org_id, references(:orgs, on_delete: :delete_all), null: false
      add :document_id, references(:documents, on_delete: :nilify_all)
      add :name, :string, null: false
      add :status, :string, null: false, default: "queued"
      add :input, :map, null: false, default: %{}
      add :result, :map, null: false, default: %{}
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps()
    end

    create index(:workflow_runs, [:org_id, :status])
    create index(:workflow_runs, [:document_id])

    create table(:workflow_steps) do
      add :workflow_run_id, references(:workflow_runs, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :position, :integer, null: false
      add :status, :string, null: false, default: "queued"
      add :assigned_to_id, references(:users, on_delete: :nilify_all)
      add :input, :map, null: false, default: %{}
      add :result, :map, null: false, default: %{}
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps()
    end

    create index(:workflow_steps, [:workflow_run_id, :position])
    create index(:workflow_steps, [:assigned_to_id, :status])

    create table(:audit_logs) do
      add :org_id, references(:orgs, on_delete: :delete_all), null: false
      add :actor_id, references(:users, on_delete: :nilify_all)
      add :action, :string, null: false
      add :entity_type, :string, null: false
      add :entity_id, :integer, null: false
      add :metadata, :map, null: false, default: %{}

      timestamps(updated_at: false)
    end

    create index(:audit_logs, [:org_id, :inserted_at])
    create index(:audit_logs, [:entity_type, :entity_id])

    create table(:integration_connections) do
      add :org_id, references(:orgs, on_delete: :delete_all), null: false
      add :entity_id, references(:org_entities, on_delete: :nilify_all)
      add :provider, :string, null: false
      add :status, :string, null: false, default: "active"
      add :external_account_id, :string, null: false
      add :label, :string
      add :credentials, :binary
      add :settings, :map, null: false, default: %{}
      add :last_synced_at, :utc_datetime_usec
      add :last_status, :string, null: false, default: "connected"
      add :last_status_at, :utc_datetime_usec
      add :last_error, :text
      add :disconnected_at, :utc_datetime_usec

      timestamps()
    end

    create index(:integration_connections, [:org_id])
    create index(:integration_connections, [:org_id, :entity_id])
    create index(:integration_connections, [:org_id, :status])
    create index(:integration_connections, [:provider, :external_account_id])
    create unique_index(:integration_connections, [:org_id, :provider, :external_account_id])
  end
end
