defmodule Nila.Development do
  @moduledoc "Small, repeatable local workspaces and their quick-login choices."
  import Ecto.Query
  alias Nila.{Accounts, Clients, Demo, Orgs, Repo}
  alias Nila.Accounts.{Scope, User}
  alias Nila.Business.{ClientAccess, Profile}
  alias Nila.Orgs.{Membership, Org}

  def setup do
    unless Application.get_env(:nila, :dev_routes, false),
      do: raise("Development setup is only available in development")

    owner = user("firm@nila.test", "Firm Owner")
    org = Repo.get_by(Org, name: "Nila Demo") || Orgs.create_org!(%{name: "Nila Demo"})
    {:ok, org} = Demo.designate(org.id)

    membership =
      Repo.get_by(Membership, org_id: org.id, user_id: owner.id) ||
        elem(Orgs.add_user(org, owner.id, "owner"), 1)

    client =
      Repo.get_by(Clients.Client, org_id: org.id, name: "Example Business") ||
        elem(
          Clients.create_client(%{
            org_id: org.id,
            name: "Example Business",
            type: "company",
            chase_channel: "none",
            gstin: "33AEWPH4158J1Z3",
            address: "12 Marina Road, Chennai, Tamil Nadu 600001"
          }),
          1
        )

    business = user("business@nila.test", "Business Owner")
    scope = %Scope{user: owner, current_org: org, membership: membership}

    {:ok, _} =
      Nila.Business.Access.invite(scope, client.id, %{name: business.name, email: business.email})

    unless Repo.get_by(Profile, client_id: client.id) do
      {:ok, _} =
        Nila.Business.Invoicing.save_profile(client, %{
          legal_name: client.name,
          address: client.address,
          state_code: "33",
          domestic_goods_and_services_only: true,
          e_invoice_not_applicable: true
        })
    end

    %{firm: org, owner: owner, business: business, client: client}
  end

  def quick_login_users do
    # Scope.for_user/1 currently opens the user's first firm membership.
    first_memberships = from m in Membership, group_by: m.user_id, select: min(m.id)

    firm =
      Repo.one(
        from u in User,
          join: m in Membership,
          on: m.user_id == u.id,
          join: o in Org,
          on: o.id == m.org_id,
          where:
            u.active and m.role == "owner" and o.is_demo and o.status == "active" and
              m.id in subquery(first_memberships),
          order_by: [desc: fragment("? = 'firm@nila.test'", u.email), asc: u.id],
          limit: 1,
          select: %{name: "Firm workspace", email: u.email}
      )

    business =
      Repo.one(
        from u in User,
          join: a in ClientAccess,
          on: a.user_id == u.id,
          join: c in Clients.Client,
          on: c.id == a.client_id,
          join: o in Org,
          on: o.id == c.org_id,
          left_join: m in Membership,
          on: m.user_id == u.id,
          where: u.active and o.is_demo and o.status == "active" and is_nil(m.id),
          order_by: [desc: fragment("? = 'business@nila.test'", u.email), asc: u.id],
          limit: 1,
          select: %{name: "Business workspace", email: u.email}
      )

    Enum.reject([firm, business], &is_nil/1)
  end

  defp user(email, name) do
    Accounts.get_user_by_email(email) ||
      Accounts.register_user!(%{email: email, name: name, password: "devpassword123"})
  end
end
