defmodule Nila.Accounts.RegistrationTest do
  use Nila.DataCase

  import Nila.AccountsFixtures
  import Swoosh.TestAssertions

  alias Nila.Accounts
  alias Nila.Accounts.User
  alias Nila.Orgs.{Membership, Org}
  alias Nila.Repo

  describe "register_user_with_org/1" do
    test "creates a user, org, and owner membership" do
      attrs = valid_signup_attributes()

      assert {:ok, %{user: user, org: org, membership: membership}} =
               Accounts.register_user_with_org(attrs)

      assert user.email == attrs.email
      assert user.name == attrs.name
      assert user.hashed_password
      assert is_nil(user.confirmed_at)
      assert org.name == attrs.org_name
      assert membership.user_id == user.id
      assert membership.org_id == org.id
      assert membership.role == "owner"
      assert Accounts.get_user_by_email_and_password(attrs.email, attrs.password)
    end

    test "rejects duplicate email and does not create an org" do
      existing = user_fixture()
      before_orgs = Repo.aggregate(Org, :count)

      assert {:error, changeset} =
               Accounts.register_user_with_org(
                 valid_signup_attributes(%{email: existing.email, org_name: "Duplicate Org"})
               )

      assert %{email: [_message]} = errors_on(changeset)
      assert Repo.aggregate(Org, :count) == before_orgs
    end

    test "rejects blank org name and does not create a user" do
      before_users = Repo.aggregate(User, :count)

      assert {:error, changeset} =
               Accounts.register_user_with_org(valid_signup_attributes(%{org_name: ""}))

      assert %{org_name: [_message]} = errors_on(changeset)
      assert Repo.aggregate(User, :count) == before_users
    end

    test "rejects mismatched passwords and does not create an org" do
      before_orgs = Repo.aggregate(Org, :count)

      assert {:error, changeset} =
               Accounts.register_user_with_org(
                 valid_signup_attributes(%{password_confirmation: "different-password"})
               )

      assert %{password_confirmation: [_message]} = errors_on(changeset)
      assert Repo.aggregate(Org, :count) == before_orgs
    end

    test "always creates owner membership" do
      attrs = valid_signup_attributes(%{role: "member"})

      assert {:ok, %{membership: membership}} = Accounts.register_user_with_org(attrs)
      assert Repo.get!(Membership, membership.id).role == "owner"
    end

    test "deliver_user_confirmation_instructions/2 sends a verification email" do
      {:ok, %{user: user}} = Accounts.register_user_with_org(valid_signup_attributes())

      assert {:ok, _email} =
               Accounts.deliver_user_confirmation_instructions(user, fn token ->
                 send(self(), {:confirmation_token, token})
                 "http://localhost/users/confirm/#{token}"
               end)

      assert_received {:confirmation_token, token}
      assert_email_sent(fn email -> assert email.text_body =~ "/users/confirm/#{token}" end)
    end

    test "confirm_user/1 confirms the user and burns the token" do
      {:ok, %{user: user}} = Accounts.register_user_with_org(valid_signup_attributes())

      Accounts.deliver_user_confirmation_instructions(user, fn token ->
        send(self(), {:confirmation_token, token})
        "http://localhost/users/confirm/#{token}"
      end)

      assert_received {:confirmation_token, token}
      assert {:ok, confirmed} = Accounts.confirm_user(token)
      assert confirmed.confirmed_at
      assert {:error, :not_found} = Accounts.confirm_user(token)
    end
  end

  defp valid_signup_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: "Signup User",
      email: unique_user_email(),
      password: valid_user_password(),
      password_confirmation: valid_user_password(),
      org_name: "Signup Org #{System.unique_integer([:positive])}"
    })
  end
end
