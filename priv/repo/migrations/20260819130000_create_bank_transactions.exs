defmodule Nila.Repo.Migrations.CreateBankTransactions do
  use Ecto.Migration

  def change do
    alter table(:bank_statements) do
      add :tally_company_id, references(:tally_companies, on_delete: :nilify_all)
    end

    create index(:bank_statements, [:tally_company_id])

    create table(:bank_transactions) do
      add :org_id, references(:orgs, on_delete: :delete_all), null: false
      add :statement_id, references(:bank_statements, on_delete: :delete_all), null: false
      add :identity, :string, null: false
      add :ordinal, :integer, null: false
      add :date, :date, null: false
      add :narration, :text, null: false
      add :reference, :string
      add :withdrawal_paise, :bigint, null: false, default: 0
      add :deposit_paise, :bigint, null: false, default: 0
      add :balance_paise, :bigint, null: false
      add :transaction_type, :string, null: false
      add :counter_ledger_identity, :string
      add :counter_ledger_name, :string
      add :status, :string, null: false, default: "unassigned"
      add :tally_job_id, references(:tally_jobs, on_delete: :nilify_all)
      add :tally_master_id, :bigint
      add :tally_guid, :string
      add :error, :map

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:bank_transactions, [:statement_id, :identity])
    create index(:bank_transactions, [:org_id, :statement_id, :status])
    create unique_index(:bank_transactions, [:tally_job_id], where: "tally_job_id IS NOT NULL")

    create constraint(:bank_transactions, :valid_transaction_type,
             check:
               "transaction_type IN ('payment', 'receipt', 'contra_withdrawal', 'contra_deposit')"
           )

    create constraint(:bank_transactions, :valid_status,
             check:
               "status IN ('unassigned', 'ready', 'queued', 'posted', 'failed', 'verifying', 'ignored')"
           )

    create constraint(:bank_transactions, :one_sided_amount,
             check:
               "(withdrawal_paise <> 0 AND deposit_paise = 0) OR (withdrawal_paise = 0 AND deposit_paise <> 0)"
           )
  end
end
