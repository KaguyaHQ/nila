defmodule Nila.ReleaseTest do
  use Nila.DataCase, async: true

  alias Nila.Accounts
  alias Nila.Orgs
  alias Nila.Repo
  alias Nila.Release

  test "create_owner/1 creates user, org, and owner membership idempotently" do
    attrs = %{
      name: "Owner User",
      email: "owner#{System.unique_integer([:positive])}@example.com",
      password: "ownerpassword123",
      org_name: "Owner Org #{System.unique_integer([:positive])}",
      legal_name: "Owner Org Private Limited",
      gstin: "33ABCDE1234F1Z7"
    }

    assert {:ok, %{user: user, org: org, membership: membership}} =
             Release.create_owner(attrs)

    assert user.email == attrs.email
    assert org.name == attrs.org_name
    assert membership.role == "owner"
    assert Accounts.get_user_by_email_and_password(attrs.email, attrs.password)

    assert {:ok, %{user: user2, org: org2}} = Release.create_owner(attrs)
    assert user2.id == user.id
    assert org2.id == org.id
    assert Orgs.owner_count(org.id) == 1
  end

  test "create_owner/1 promotes an existing non-owner membership" do
    attrs = %{
      name: "Existing User",
      email: "existing#{System.unique_integer([:positive])}@example.com",
      password: "ownerpassword123",
      org_name: "Existing Org #{System.unique_integer([:positive])}",
      legal_name: "Existing Org Private Limited",
      gstin: "32ABCDE1234F1Z9"
    }

    user = Accounts.register_user!(Map.take(attrs, [:name, :email, :password]))

    org =
      Orgs.create_org!(%{name: attrs.org_name, legal_name: attrs.legal_name, gstin: attrs.gstin})

    {:ok, membership} = Orgs.add_user(org, user.id, "member")

    assert {:ok, %{membership: promoted}} = Release.create_owner(attrs)
    assert promoted.id == membership.id
    assert Repo.reload!(promoted).role == "owner"
  end
end
