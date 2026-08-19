defmodule Nila.Repo.Migrations.AddBankLedgerIdentity do
  use Ecto.Migration

  def change do
    alter table(:bank_statements) do
      add :bank_ledger_identity, :string
    end
  end
end
