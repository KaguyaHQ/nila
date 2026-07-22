defmodule Nila.Repo.Migrations.DropWorkflowTables do
  use Ecto.Migration

  # The generic Workflows.Run/Step scaffolding was stillborn substrate carried
  # over from the service-ops repo; the GST intake pipeline (Dump → DumpWorker →
  # ExtractionAttempt) reifies the same shape in domain terms and nothing ever
  # drove these tables. Drop them.

  def up do
    drop table(:workflow_steps)
    drop table(:workflow_runs)
  end

  def down do
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
  end
end
