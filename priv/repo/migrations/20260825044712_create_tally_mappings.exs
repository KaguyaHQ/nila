defmodule Nila.Repo.Migrations.CreateTallyMappings do
  use Ecto.Migration

  def up do
    create table(:tally_party_mappings) do
      add :org_id, references(:orgs, on_delete: :delete_all), null: false
      add :company_id, references(:tally_companies, on_delete: :delete_all), null: false
      add :source_key, :string, null: false
      add :gstin, :string
      add :normalized_name, :string
      add :ledger_identity, :string, null: false
      add :confirmation_source, :string, null: false, default: "manual"
      add :confirmed_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tally_party_mappings, [:company_id, :source_key])
    create index(:tally_party_mappings, [:org_id, :company_id])
    create index(:tally_party_mappings, [:company_id, :ledger_identity])

    create table(:tally_posting_profiles) do
      add :org_id, references(:orgs, on_delete: :delete_all), null: false
      add :company_id, references(:tally_companies, on_delete: :delete_all), null: false
      add :sales_ledger_identity, :string
      add :cgst_ledger_identity, :string
      add :sgst_ledger_identity, :string
      add :igst_ledger_identity, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tally_posting_profiles, [:company_id])
    create index(:tally_posting_profiles, [:org_id, :company_id])
  end

  def down do
    drop_if_exists table(:tally_posting_profiles)
    drop_if_exists table(:tally_party_mappings)
  end
end
