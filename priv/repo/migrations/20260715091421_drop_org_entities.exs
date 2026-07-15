defmodule Nila.Repo.Migrations.DropOrgEntities do
  use Ecto.Migration

  def up do
    drop index(:integration_connections, [:org_id, :entity_id])
    alter table(:integration_connections) do
      remove :entity_id
    end

    drop unique_index(:bank_accounts, [:org_id, :entity_id, :account_number_masked, :ifsc],
           name: :bank_accounts_org_entity_account_ifsc_index
         )

    drop index(:bank_accounts, [:org_id, :entity_id])

    alter table(:bank_accounts) do
      remove :entity_id
    end

    create unique_index(:bank_accounts, [:org_id, :account_number_masked, :ifsc],
             name: :bank_accounts_org_account_ifsc_index
           )

    drop table(:org_entities)
  end

  def down do
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

    drop unique_index(:bank_accounts, [:org_id, :account_number_masked, :ifsc],
           name: :bank_accounts_org_account_ifsc_index
         )

    alter table(:bank_accounts) do
      add :entity_id, references(:org_entities, on_delete: :delete_all)
    end

    create index(:bank_accounts, [:org_id, :entity_id])

    create unique_index(:bank_accounts, [:org_id, :entity_id, :account_number_masked, :ifsc],
             name: :bank_accounts_org_entity_account_ifsc_index
           )

    alter table(:integration_connections) do
      add :entity_id, references(:org_entities, on_delete: :nilify_all)
    end

    create index(:integration_connections, [:org_id, :entity_id])
  end
end
