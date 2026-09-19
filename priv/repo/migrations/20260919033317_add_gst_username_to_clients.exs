defmodule Nila.Repo.Migrations.AddGstUsernameToClients do
  use Ecto.Migration

  def change do
    alter table(:clients) do
      add :gst_username, :string
    end
  end
end
