defmodule Nila.Orgs.Membership do
  use Nila.Schema
  import Ecto.Changeset

  @roles ~w(owner admin member viewer)

  schema "org_memberships" do
    field :role, :string, default: "member"

    belongs_to :org, Nila.Orgs.Org
    belongs_to :user, Nila.Accounts.User

    timestamps()
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:org_id, :user_id, :role])
    |> validate_required([:org_id, :user_id, :role])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint([:org_id, :user_id])
  end

  def role_changeset(membership, role) do
    membership
    |> cast(%{role: role}, [:role])
    |> validate_required([:role])
    |> validate_inclusion(:role, @roles)
  end

  def roles, do: @roles
end
