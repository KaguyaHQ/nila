defmodule Nila.Repo.Migrations.AllowIndeterminateTallyJobs do
  use Ecto.Migration

  def up do
    drop constraint(:tally_jobs, :valid_status)

    create constraint(:tally_jobs, :valid_status,
             check: "status IN ('pending', 'running', 'succeeded', 'failed', 'indeterminate')"
           )
  end

  def down do
    execute("UPDATE tally_jobs SET status = 'failed' WHERE status = 'indeterminate'")
    drop constraint(:tally_jobs, :valid_status)

    create constraint(:tally_jobs, :valid_status,
             check: "status IN ('pending', 'running', 'succeeded', 'failed')"
           )
  end
end
