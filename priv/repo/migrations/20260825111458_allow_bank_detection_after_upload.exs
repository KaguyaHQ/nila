defmodule Nila.Repo.Migrations.AllowBankDetectionAfterUpload do
  use Ecto.Migration

  def change do
    alter table(:bank_statements) do
      modify :bank_code, :string, null: true, from: {:string, null: false}
      modify :bank_name, :string, null: true, from: {:string, null: false}
      modify :bank_ledger_name, :string, null: true, from: {:string, null: false}
    end
  end
end
