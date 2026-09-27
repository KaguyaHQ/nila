defmodule Nila.Business.AccessTest do
  use Nila.DataCase, async: true
  import Nila.AccountsFixtures
  alias Nila.{Accounts, Clients, Repo}
  alias Nila.Accounts.Scope
  alias Nila.Business.{Access, ClientAccess}

  setup do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{org_id: org.id, name: "Service business", type: "company"})

    %{scope: Scope.for_user(user), client: client}
  end

  test "invitation grants only business access and password acceptance preserves isolation", %{
    scope: scope,
    client: client
  } do
    attrs = %{name: "Business owner", email: unique_user_email()}
    assert {:ok, result} = Access.invite(scope, client.id, attrs)
    assert Accounts.get_user_by_invite_token(result.token).id == result.user.id
    assert {:ok, user} = Accounts.accept_invite(result.user, %{password: valid_user_password()})
    business_scope = Scope.for_user(user)
    assert business_scope.business_client.id == client.id
    assert is_nil(business_scope.current_org)
    assert is_nil(business_scope.membership)
    refute Nila.Accounts.Policy.can?(business_scope, :view)
    assert {:ok, repeated} = Access.invite(scope, client.id, attrs)
    assert repeated.already_active
    assert is_nil(repeated.token)
    assert repeated.user.hashed_password == user.hashed_password
  end

  test "operators and cross-firm clients are refused; firm users keep firm access", %{
    scope: scope,
    client: client
  } do
    %{user: operator} = user_with_org_fixture(%{role: "member"})
    attrs = %{name: "Owner", email: unique_user_email()}
    assert {:error, :forbidden} = Access.invite(Scope.for_user(operator), client.id, attrs)
    %{user: other} = user_with_org_fixture()
    assert {:error, :not_found} = Access.invite(Scope.for_user(other), client.id, attrs)

    assert {:ok, result} =
             Access.invite(scope, client.id, %{name: "Owner", email: other.email})

    assert result.user.id == other.id
    assert result.already_active
    assert is_nil(result.token)
    assert Access.client_for_user(other.id, client.id).id == client.id
    assert Scope.for_user(other).current_org.id != client.org_id

    refute Repo.exists?(
             from m in Nila.Orgs.Membership,
               where: m.user_id == ^other.id and m.org_id == ^client.org_id
           )
  end

  test "business user can access several clients but no other client", %{
    scope: scope,
    client: client
  } do
    attrs = %{name: "Owner", email: unique_user_email()}
    {:ok, _} = Access.invite(scope, client.id, attrs)

    {:ok, second} =
      Clients.create_client(%{org_id: client.org_id, name: "Second business", type: "company"})

    assert {:ok, _} = Access.invite(scope, second.id, attrs)
    user = Accounts.get_user_by_email(attrs.email)
    assert Enum.map(Access.list_clients_for_user(user.id), & &1.id) == [second.id, client.id]
    assert Access.client_for_user(user.id, Integer.to_string(second.id)).id == second.id
    assert Access.client_for_user(user.id, "nope") == nil
    assert Access.client_for_user(user.id, "-1") == nil
    assert Access.client_for_user(user.id, "999999999999999999999999999") == nil
    assert Access.client_for_user(user.id, nil) == nil
    assert Access.client_for_user(user.id, 0) == nil
    assert Access.client_for_user(user.id, client.id + second.id + 100) == nil
    assert length(Repo.all(from a in ClientAccess, where: a.user_id == ^user.id)) == 2
  end

  test "existing user can create two businesses without receiving firm membership" do
    %{user: user, org: firm} = user_with_org_fixture()

    assert {:ok, first} =
             Access.create_business_for_user(user, %{name: "Caltech", gstin: "27AAPFU0939F1ZV"})

    assert {:ok, second} =
             Access.create_business_for_user(user, %{
               name: "Breeze Tech",
               gstin: "33AEWPH4158J1Z3"
             })

    assert first.user.id == user.id
    assert second.user.id == user.id
    assert first.org.id != second.org.id
    assert first.client.org_id == first.org.id
    assert second.client.org_id == second.org.id

    assert Enum.map(Access.list_clients_for_user(user.id), & &1.id) ==
             [second.client.id, first.client.id]

    assert Scope.for_user(user).current_org.id == firm.id

    assert Repo.aggregate(from(m in Nila.Orgs.Membership, where: m.user_id == ^user.id), :count) ==
             1
  end

  test "invalid business creation for an existing user writes no rows" do
    %{user: user} = user_with_org_fixture()

    assert {:error, %Ecto.Changeset{}} =
             Access.create_business_for_user(user, %{name: "Invalid business", gstin: "invalid"})

    assert Access.list_clients_for_user(user.id) == []
    refute Repo.exists?(from o in Nila.Orgs.Org, where: o.name == "Invalid business")
  end

  test "independent signup creates a private business and business-only scope" do
    email = unique_user_email()

    assert {:ok, %{user: user, org: org, client: client}} =
             Access.register_business(
               %{
                 name: "New owner",
                 email: email,
                 password: valid_user_password(),
                 password_confirmation: valid_user_password()
               },
               %{name: "Studio", gstin: "27AAPFU0939F1ZV"}
             )

    assert is_nil(user.confirmed_at)
    assert org.name == "Studio"
    assert client.org_id == org.id
    assert client.type == "company"
    assert client.gstin == "27AAPFU0939F1ZV"
    refute Repo.exists?(from m in Nila.Orgs.Membership, where: m.user_id == ^user.id)
    scope = Scope.for_user(user)
    assert scope.business_client.id == client.id
    assert is_nil(scope.current_org)
    assert is_nil(scope.membership)
  end

  test "invalid GSTIN or duplicate email leaves no signup rows" do
    %{user: existing} = user_with_org_fixture()
    email = unique_user_email()

    assert {:error, %Ecto.Changeset{}} =
             Access.register_business(
               %{
                 name: "New owner",
                 email: email,
                 password: valid_user_password(),
                 password_confirmation: valid_user_password()
               },
               %{name: "Studio", gstin: "invalid"}
             )

    refute Accounts.get_user_by_email(email)
    refute Repo.exists?(from o in Nila.Orgs.Org, where: o.name == "Studio")

    assert {:error, %Ecto.Changeset{}} =
             Access.register_business(
               %{
                 name: "New owner",
                 email: existing.email,
                 password: valid_user_password(),
                 password_confirmation: valid_user_password()
               },
               %{name: "Studio", gstin: "27AAPFU0939F1ZV"}
             )

    refute Accounts.get_user_by_email(email)
    refute Repo.exists?(from o in Nila.Orgs.Org, where: o.name == "Studio")

    invalid_password_email = unique_user_email()

    assert {:error, %Ecto.Changeset{}} =
             Access.register_business(
               %{
                 name: "New owner",
                 email: invalid_password_email,
                 password: "short",
                 password_confirmation: "short"
               },
               %{name: "Studio", gstin: "27AAPFU0939F1ZV"}
             )

    refute Accounts.get_user_by_email(invalid_password_email)
    refute Repo.exists?(from o in Nila.Orgs.Org, where: o.name == "Studio")
  end
end
