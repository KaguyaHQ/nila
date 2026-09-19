defmodule Nila.Repo.Migrations.CreateNoticeCheckRuns do
  use Ecto.Migration

  def change do
    create table(:notice_check_runs) do
      add :org_id, references(:orgs, on_delete: :delete_all), null: false
      add :results, :map, null: false, default: %{}
      add :baseline_notice_id, :bigint, null: false, default: 0
      add :notice_ids, {:array, :bigint}, null: false, default: []
      timestamps(type: :utc_datetime_usec)
    end

    create index(:notice_check_runs, [:org_id, :id])
  end
end
