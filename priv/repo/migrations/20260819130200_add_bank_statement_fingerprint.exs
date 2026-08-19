defmodule Nila.Repo.Migrations.AddBankStatementFingerprint do
  use Ecto.Migration

  def change do
    alter table(:bank_statements) do
      add :source_sha256, :binary
    end

    create unique_index(:bank_statements, [:org_id, :client_id, :source_sha256],
             where: "source_sha256 IS NOT NULL"
           )
  end
end
