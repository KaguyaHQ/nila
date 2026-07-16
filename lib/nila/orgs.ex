defmodule Nila.Orgs do
  import Ecto.Query

  alias Nila.Orgs.{Membership, Org}
  alias Nila.Repo

  def list_orgs do
    Repo.all(from org in Org, order_by: [asc: org.name])
  end

  def get_org!(id), do: Repo.get!(Org, id)

  def create_org(attrs) do
    %Org{}
    |> Org.changeset(attrs)
    |> Repo.insert()
  end

  def create_org!(attrs) do
    %Org{}
    |> Org.changeset(attrs)
    |> Repo.insert!()
  end

  def update_org(%Org{} = org, attrs) do
    org
    |> Org.changeset(attrs)
    |> Repo.update()
  end

  def add_user(%Org{} = org, user_id, role \\ "member") do
    %Membership{}
    |> Membership.changeset(%{org_id: org.id, user_id: user_id, role: role})
    |> Repo.insert()
  end

  @doc """
  Lists an org's memberships with their users, ordered by member name.
  """
  def list_memberships(org_id) do
    Repo.all(
      from membership in Membership,
        join: user in assoc(membership, :user),
        where: membership.org_id == ^org_id,
        order_by: [asc: user.name],
        preload: [user: user]
    )
  end

  def get_membership!(id), do: Repo.get!(Membership, id)

  @doc """
  Updates a membership's role.

  Refuses to demote the last owner of an org so a firm can never be left
  without one. Returns `{:error, :last_owner}` in that case.
  """
  def update_membership_role(%Membership{} = membership, role) do
    if demoting_last_owner?(membership, role) do
      {:error, :last_owner}
    else
      membership
      |> Membership.role_changeset(role)
      |> Repo.update()
    end
  end

  @doc "Counts the owner memberships in an org."
  def owner_count(org_id) do
    Repo.aggregate(
      from(membership in Membership,
        where: membership.org_id == ^org_id and membership.role == "owner"
      ),
      :count
    )
  end

  defp demoting_last_owner?(%Membership{role: "owner", org_id: org_id}, new_role)
       when new_role != "owner",
       do: owner_count(org_id) <= 1

  defp demoting_last_owner?(_membership, _new_role), do: false

  def change_org(%Org{} = org, attrs \\ %{}) do
    Org.changeset(org, attrs)
  end
end
