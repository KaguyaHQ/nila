defmodule Nila.Repo.Migrations.AddPayloadHashToTallyJobs do
  use Ecto.Migration

  def change do
    alter table(:tally_jobs) do
      add :payload_hash, :binary
    end
  end
end
