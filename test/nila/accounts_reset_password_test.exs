defmodule Nila.AccountsResetPasswordTest do
  use Nila.DataCase, async: true

  import Nila.AccountsFixtures
  import Swoosh.TestAssertions

  alias Nila.Accounts
  alias Nila.Accounts.UserToken
  alias Nila.Repo

  defp reset_url_fun(test_pid \\ self()) do
    fn token ->
      send(test_pid, {:reset_token, token})
      "http://localhost/users/reset_password/#{token}"
    end
  end

  test "deliver_user_reset_password_instructions/2 sends only for known emails but always returns ok" do
    user = user_fixture()

    assert :ok =
             Accounts.deliver_user_reset_password_instructions(
               " #{String.upcase(user.email)} ",
               reset_url_fun()
             )

    assert_received {:reset_token, _token}
    assert_email_sent(fn email -> assert email.text_body =~ "/users/reset_password/" end)

    assert :ok =
             Accounts.deliver_user_reset_password_instructions(
               "missing@example.com",
               reset_url_fun()
             )

    refute_received {:reset_token, _token}
  end

  test "get_user_by_reset_password_token/1 resolves valid token only" do
    user = user_fixture()
    Accounts.deliver_user_reset_password_instructions(user.email, reset_url_fun())
    assert_received {:reset_token, token}

    assert resolved = Accounts.get_user_by_reset_password_token(token)
    assert resolved.id == user.id
    assert is_nil(Accounts.get_user_by_reset_password_token("garbage"))

    [row] = Repo.all(UserToken.by_user_and_contexts_query(user, ["reset_password"]))

    Repo.update_all(UserToken.by_token_and_context_query(row.token, "reset_password"),
      set: [inserted_at: ~U[2000-01-01 00:00:00Z]]
    )

    assert is_nil(Accounts.get_user_by_reset_password_token(token))
  end

  test "reset_user_password/3 writes password and burns sessions and reset tokens" do
    user = user_fixture()
    session_token = Accounts.generate_user_session_token(user)
    token = reset_token(user)

    assert {:ok, user} =
             Accounts.reset_user_password(user, token, %{
               password: "newpassword123",
               password_confirmation: "newpassword123"
             })

    assert Accounts.get_user_by_email_and_password(user.email, "newpassword123")
    assert is_nil(Accounts.get_user_by_session_token(session_token))
    assert is_nil(Accounts.get_user_by_reset_password_token(token))
  end

  test "reset_user_password/3 rejects weak or mismatched passwords" do
    user = user_fixture()

    assert {:error, changeset} =
             Accounts.reset_user_password(user, reset_token(user), %{
               password: "short",
               password_confirmation: "short"
             })

    refute changeset.valid?

    assert {:error, changeset} =
             Accounts.reset_user_password(user, reset_token(user), %{
               password: "newpassword123",
               password_confirmation: "different123"
             })

    refute changeset.valid?
  end

  test "reset_user_password/3 rejects a stale or wrong-context token" do
    org = org_fixture()
    user = user_fixture()

    {:ok, invited} =
      Accounts.invite_user(org, %{name: "Invited", email: unique_user_email()}, fn token ->
        send(self(), {:invite_token, token})
        "http://localhost/users/invite/#{token}"
      end)

    assert_received {:invite_token, invite_token}

    assert {:error, :not_found} =
             Accounts.reset_user_password(invited, invite_token, %{
               password: "newpassword123",
               password_confirmation: "newpassword123"
             })

    token = reset_token(user)

    assert {:ok, _user} =
             Accounts.reset_user_password(user, token, %{
               password: "newpassword123",
               password_confirmation: "newpassword123"
             })

    assert {:error, :not_found} =
             Accounts.reset_user_password(user, token, %{
               password: "anotherpassword123",
               password_confirmation: "anotherpassword123"
             })
  end

  defp reset_token(user) do
    Accounts.deliver_user_reset_password_instructions(user.email, reset_url_fun())
    assert_received {:reset_token, token}
    token
  end
end
