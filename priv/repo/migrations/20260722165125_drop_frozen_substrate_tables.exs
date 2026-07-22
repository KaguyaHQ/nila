defmodule Nila.Repo.Migrations.DropFrozenSubstrateTables do
  use Ecto.Migration

  # Retires the generic document/banking/audit substrate the GST product
  # outgrew: `Documents` (Document/Artifact) was the wrong-altitude HITL engine
  # replaced by `Gst.Intake`; `Banking` was built for the abandoned bank-
  # classification thesis; `Audits` was replaced by `ExtractionAttempt` +
  # `Signoffs`. The code was deleted alongside this migration. A permanent
  # retirement, so `down/0` is a one-way door — the table definitions live in
  # git history (20260526184134_create_substrate_tables,
  # 20260622061747_create_bank_tables) and the nila-ops archive if ever needed.

  def up do
    # Child-before-parent for FK order.
    drop table(:bank_transactions)
    drop table(:bank_accounts)
    drop table(:document_artifacts)
    drop table(:documents)
    drop table(:audit_logs)
  end

  def down do
    raise Ecto.MigrationError,
      message:
        "drop_frozen_substrate_tables is irreversible; restore the schema from " <>
          "git history (create_substrate_tables / create_bank_tables) if needed."
  end
end
