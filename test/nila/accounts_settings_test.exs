defmodule Nila.AccountsSettingsTest do
  use Nila.DataCase, async: true

  import Nila.AccountsFixtures
  import Swoosh.TestAssertions

  alias Nila.Accounts

  defp email_url_fun(test_pid \\ self()) do
    fn token ->
      send(test_pid, {:change_email_token, token})
      "http://localhost/settings/profile/confirm_email/#{token}"
    end
  end

  test "update_user_password/3 requires current password and revokes sessions/reset tokens" do
    user = user_fixture()
    session_token = Accounts.generate_user_session_token(user)

    Accounts.deliver_user_reset_password_instructions(user.email, fn token ->
      send(self(), {:reset_token, token})
      "http://reset/#{token}"
    end)

    assert_received {:reset_token, reset_token}

    assert {:error, changeset} =
             Accounts.update_user_password(user, "wrong", %{
               password: "newpassword123",
               password_confirmation: "newpassword123"
             })

    refute changeset.valid?

    assert {:ok, _user} =
             Accounts.update_user_password(user, valid_user_password(), %{
               password: "newpassword123",
               password_confirmation: "newpassword123"
             })

    assert Accounts.get_user_by_email_and_password(user.email, "newpassword123")
    assert is_nil(Accounts.get_user_by_session_token(session_token))
    assert is_nil(Accounts.get_user_by_reset_password_token(reset_token))
  end

  test "deliver_user_update_email_instructions/4 validates and sends to new email" do
    user = user_fixture()

    assert {:error, changeset} =
             Accounts.deliver_user_update_email_instructions(
               user,
               "wrong",
               %{"email" => "new@example.com"},
               email_url_fun()
             )

    refute changeset.valid?
    refute_email_sent()

    assert {:ok, "new@example.com"} =
             Accounts.deliver_user_update_email_instructions(
               user,
               valid_user_password(),
               %{"email" => "New@Example.com"},
               email_url_fun()
             )

    assert_received {:change_email_token, _token}
    assert_email_sent(to: [{nil, "new@example.com"}])
  end

  test "update_user_email/2 applies a valid token and burns it" do
    user = user_fixture()

    assert {:ok, _email} =
             Accounts.deliver_user_update_email_instructions(
               user,
               valid_user_password(),
               %{"email" => "updated@example.com"},
               email_url_fun()
             )

    assert_received {:change_email_token, token}
    assert {:ok, updated} = Accounts.update_user_email(user, token)
    assert updated.email == "updated@example.com"
    assert {:error, :not_found} = Accounts.update_user_email(updated, token)
  end

  test "update_user_email/2 rejects duplicate emails" do
    existing = user_fixture()
    user = user_fixture()

    assert {:error, changeset} =
             Accounts.deliver_user_update_email_instructions(
               user,
               valid_user_password(),
               %{"email" => existing.email},
               email_url_fun()
             )

    refute changeset.valid?
  end
end
