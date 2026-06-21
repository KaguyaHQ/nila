defmodule NilaWeb.UserSettingsLiveTest do
  use NilaWeb.ConnCase

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias Nila.Accounts

  defp email_url_fun(test_pid \\ self()) do
    fn token ->
      send(test_pid, {:change_email_token, token})
      "http://localhost/settings/account/confirm_email/#{token}"
    end
  end

  test "requires authentication", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log_in"}}} = live(conn, ~p"/settings/account")
  end

  test "renders both settings forms", %{conn: conn} do
    %{user: user} = user_with_org_fixture()

    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/settings/account")

    assert has_element?(view, "#account-settings-page")
    assert has_element?(view, "#change-password-form")
    assert has_element?(view, "#change-email-form")
  end

  test "email change form sends confirmation to new address", %{conn: conn} do
    %{user: user} = user_with_org_fixture()

    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/settings/account")

    view
    |> form("#change-email-form",
      email_user: %{email: "new-live@example.com", current_password: valid_user_password()}
    )
    |> render_submit()

    assert_email_sent(to: [{nil, "new-live@example.com"}])
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

    assert {:error, {:live_redirect, %{to: "/settings/account"}}} =
             conn |> log_in_user(user) |> live(~p"/settings/account/confirm_email/#{token}")

    assert Accounts.get_user_by_email("confirmed-live@example.com")
  end
end
