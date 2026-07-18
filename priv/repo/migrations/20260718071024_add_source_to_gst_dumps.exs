defmodule Nila.Repo.Migrations.AddSourceToGstDumps do
  use Ecto.Migration

  def change do
    alter table(:gst_dumps) do
      add :source, :string
    end
  end
end
