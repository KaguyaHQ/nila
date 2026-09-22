defmodule Nila.Repo.Migrations.AddGstr2bFailureDetails do
  use Ecto.Migration

  def change do
    alter table(:gst_portal_statements) do
      add :failure_reason, :string
      add :provider_code, :string
    end
  end
end
