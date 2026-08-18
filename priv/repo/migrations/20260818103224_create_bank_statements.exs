defmodule Nila.Repo.Migrations.CreateBankStatements do
  use Ecto.Migration

  def change do
    create table(:bank_statements) do
      add :org_id, references(:orgs, on_delete: :delete_all), null: false
      add :client_id, references(:clients, on_delete: :delete_all), null: false
      add :brought_in_by_id, references(:users, on_delete: :nilify_all)
      add :bank_code, :string, null: false
      add :bank_name, :string, null: false
      add :bank_ledger_name, :string, null: false
      add :status, :string, null: false, default: "received"
      add :source_key, :string, null: false
      add :original_filename, :string, null: false
      add :source_credentials, :binary
      add :account_number_masked, :string
      add :statement_from, :date
      add :statement_to, :date
      add :opening_balance_paise, :bigint
      add :closing_balance_paise, :bigint
      add :total_withdrawal_paise, :bigint
      add :total_deposit_paise, :bigint
      add :transaction_count, :integer, null: false, default: 0
      add :transactions, {:array, :map}, null: false, default: []
      add :meta, :map, null: false, default: %{}
      add :error, :text

      timestamps()
    end

    create index(:bank_statements, [:org_id, :inserted_at])
    create index(:bank_statements, [:org_id, :client_id, :statement_from])
  end
end
