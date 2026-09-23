defmodule NilaWeb.ProfileEmailConfirmationControllerTest do
  use NilaWeb.ConnCase, async: true

  alias Nila.Accounts

  defp email_url_fun(test_pid \\ self()) do
    fn token ->
      send(test_pid, {:change_email_token, token})
      "http://localhost/settings/profile/confirm_email/#{token}"
    end
  end

  test "confirm email link applies change", %{conn: conn} do
    %{user: user} = user_with_org_fixture()

    assert {:ok, _email} =
             Accounts.deliver_user_update_email_instructions(
               user,
               valid_user_password(),
               %{"email" => "confirmed-live@example.com"},
               email_url_fun()
             )

    assert_received {:change_email_token, token}

    assert conn
           |> log_in_user(user)
           |> get(~p"/settings/profile/confirm_email/#{token}")
           |> redirected_to() == "/app/settings/profile?email=confirmed"

    assert Accounts.get_user_by_email("confirmed-live@example.com")
  end
end
