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

  test "operators, cross-firm clients, and existing firm users are refused", %{
    scope: scope,
    client: client
  } do
    %{user: operator} = user_with_org_fixture(%{role: "member"})
    attrs = %{name: "Owner", email: unique_user_email()}
    assert {:error, :forbidden} = Access.invite(Scope.for_user(operator), client.id, attrs)
    %{user: other} = user_with_org_fixture()
    assert {:error, :not_found} = Access.invite(Scope.for_user(other), client.id, attrs)

    assert {:error, :firm_user} =
             Access.invite(scope, client.id, %{name: "Owner", email: other.email})

    refute Repo.exists?(from access in ClientAccess, where: access.client_id == ^client.id)
  end

  test "business user cannot be attached to a second client", %{scope: scope, client: client} do
    attrs = %{name: "Owner", email: unique_user_email()}
    {:ok, _} = Access.invite(scope, client.id, attrs)

    {:ok, second} =
      Clients.create_client(%{org_id: client.org_id, name: "Second business", type: "company"})

    assert {:error, :other_business} = Access.invite(scope, second.id, attrs)
  end
end
