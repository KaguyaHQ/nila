defmodule Nila.Business.ClientAccess do
  use Nila.Schema
  import Ecto.Changeset

  schema "business_client_accesses" do
    belongs_to :user, Nila.Accounts.User
    belongs_to :client, Nila.Clients.Client
    timestamps()
  end

  def changeset(access) do
    access
    |> change()
    |> validate_required([:user_id, :client_id])
    |> unique_constraint([:user_id, :client_id])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:client_id)
  end
end
