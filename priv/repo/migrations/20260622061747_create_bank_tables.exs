defmodule Nila.Repo.Migrations.CreateBankTables do
  use Ecto.Migration

  def change do
    create table(:bank_accounts) do
      add :org_id, references(:orgs, on_delete: :delete_all), null: false
      add :entity_id, references(:org_entities, on_delete: :delete_all), null: false
      add :account_number_masked, :string
      add :ifsc, :string
      add :bank_name, :string
      add :label, :string

      timestamps()
    end

    create index(:bank_accounts, [:org_id])
    create index(:bank_accounts, [:org_id, :entity_id])

    create unique_index(:bank_accounts, [:org_id, :entity_id, :account_number_masked, :ifsc],
             name: :bank_accounts_org_entity_account_ifsc_index
           )

    create table(:bank_transactions) do
      add :org_id, references(:orgs, on_delete: :delete_all), null: false
      add :bank_account_id, references(:bank_accounts, on_delete: :delete_all), null: false
      add :txn_date, :date
      add :value_date, :date
      add :amount, :decimal, null: false
      add :direction, :string, null: false
      add :balance, :decimal
      add :narration, :string
      add :ref, :string
      add :mode, :string
      add :txn_id, :string, null: false
      add :raw, :map, null: false, default: %{}

      timestamps()
    end

    create index(:bank_transactions, [:org_id])
    create index(:bank_transactions, [:bank_account_id, :txn_date])
    create unique_index(:bank_transactions, [:bank_account_id, :txn_id])
  end
end
