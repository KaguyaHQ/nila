defmodule Nila.Repo.Migrations.AddFirmIdentityToOrgs do
  use Ecto.Migration

  def change do
    alter table(:orgs) do
      add :address_line1, :string
      add :address_line2, :string
      add :city, :string
      add :state, :string
      add :postal_code, :string
      add :country, :string, null: false, default: "India"
      add :contact_email, :citext
      add :contact_phone, :string
    end
  end
end
