defmodule Nila.AccountsInviteTest do
  use Nila.DataCase, async: true

  import Nila.AccountsFixtures
  import Swoosh.TestAssertions

  alias Nila.Accounts
  alias Nila.Orgs

  defp url_fun do
    test_pid = self()

    fn token ->
      send(test_pid, {:invite_token, token})
      "http://localhost/users/invite/#{token}"
    end
  end

  describe "invite_user/3" do
    setup do
      %{org: org_fixture()}
    end

    test "creates an invited user, membership, and token, then emails the link", %{org: org} do
      attrs = %{name: "Jaimathi", email: "Jaimathi@Example.com", role: "member"}

      assert {:ok, user} = Accounts.invite_user(org, attrs, url_fun())

      assert user.email == "jaimathi@example.com"
      assert user.active
      assert is_nil(user.hashed_password)

      assert [membership] = Orgs.list_memberships(org.id)
      assert membership.role == "member"
      assert membership.user_id == user.id

      assert_received {:invite_token, _token}
      assert_email_sent(fn email -> assert email.text_body =~ "/users/invite/" end)
    end

    test "refuses to invite someone already in the workspace", %{org: org} do
      attrs = %{name: "Hema", email: "hema@example.com", role: "owner"}

      assert {:ok, _user} = Accounts.invite_user(org, attrs, url_fun())
      assert {:error, :already_member} = Accounts.invite_user(org, attrs, url_fun())
    end

    test "validates the invite form changeset" do
      changeset = Accounts.change_invite(%{"name" => "", "email" => "nope", "role" => "boss"})

      refute changeset.valid?
      assert %{email: _, name: _, role: _} = errors_on(changeset)
    end
  end

  describe "accepting an invite" do
    setup do
      org = org_fixture()

      {:ok, user} =
        Accounts.invite_user(org, %{name: "Kannan", email: "kannan@example.com"}, url_fun())

      assert_received {:invite_token, token}
      %{org: org, user: user, token: token}
    end

    test "resolves a valid token to the user", %{user: user, token: token} do
      assert resolved = Accounts.get_user_by_invite_token(token)
      assert resolved.id == user.id
    end

    test "rejects a garbage token" do
      assert is_nil(Accounts.get_user_by_invite_token("not-a-real-token"))
    end

    test "sets the password, confirms, and burns the token (single use)", %{
      user: user,
      token: token
    } do
      assert {:ok, accepted} =
               Accounts.accept_invite(user, %{
                 password: "supersecret123",
                 password_confirmation: "supersecret123"
               })

      refute is_nil(accepted.hashed_password)
      refute is_nil(accepted.confirmed_at)

      # The token is single-use.
      assert is_nil(Accounts.get_user_by_invite_token(token))

      # And the user can now authenticate.
      assert authed =
               Accounts.get_user_by_email_and_password("kannan@example.com", "supersecret123")

      assert authed.id == user.id
    end

    test "rejects a too-short or mismatched password", %{user: user} do
      assert {:error, _} =
               Accounts.accept_invite(user, %{password: "short", password_confirmation: "short"})

      assert {:error, _} =
               Accounts.accept_invite(user, %{
                 password: "supersecret123",
                 password_confirmation: "different12345"
               })
    end
  end

  describe "set_user_active/2" do
    test "a disabled user cannot authenticate" do
      org = org_fixture()

      {:ok, user} =
        Accounts.invite_user(org, %{name: "Temp", email: "temp@example.com"}, url_fun())

      {:ok, user} =
        Accounts.accept_invite(user, %{
          password: "supersecret123",
          password_confirmation: "supersecret123"
        })

      assert Accounts.get_user_by_email_and_password("temp@example.com", "supersecret123")

      {:ok, _} = Accounts.set_user_active(user, false)
      refute Accounts.get_user_by_email_and_password("temp@example.com", "supersecret123")
    end
  end
end
