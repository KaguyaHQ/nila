defmodule NilaWeb.UserResetPasswordLiveTest do
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Nila.Accounts

  defp reset_url_fun(test_pid \\ self()) do
    fn token ->
      send(test_pid, {:reset_token, token})
      "http://localhost/users/reset_password/#{token}"
    end
  end

  test "forgot password redirects with generic message for unknown email", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/users/reset_password")

    assert view
           |> form("#forgot-password-form", user: %{email: "missing@example.com"})
           |> render_submit()

    assert_redirected(view, ~p"/users/log_in")
  end

  test "reset page renders valid token form and resets password", %{conn: conn} do
    user = user_fixture()
    Accounts.deliver_user_reset_password_instructions(user.email, reset_url_fun())
    assert_received {:reset_token, token}

    {:ok, view, _html} = live(conn, ~p"/users/reset_password/#{token}")
    assert has_element?(view, "#reset-password-valid")

    view
    |> form("#reset-password-form",
      user: %{password: "newpassword123", password_confirmation: "newpassword123"}
    )
    |> render_submit()

    assert_redirected(view, ~p"/users/log_in")
    assert Accounts.get_user_by_email_and_password(user.email, "newpassword123")
  end

  test "reset submit rejects a token consumed after mount", %{conn: conn} do
    user = user_fixture()
    Accounts.deliver_user_reset_password_instructions(user.email, reset_url_fun())
    assert_received {:reset_token, token}

    {:ok, view, _html} = live(conn, ~p"/users/reset_password/#{token}")

    assert {:ok, _user} =
             Accounts.reset_user_password(user, token, %{
               password: "alreadyreset123",
               password_confirmation: "alreadyreset123"
             })

    view
    |> form("#reset-password-form",
      user: %{password: "stalereset123", password_confirmation: "stalereset123"}
    )
    |> render_submit()

    assert_redirected(view, ~p"/users/reset_password")
    refute Accounts.get_user_by_email_and_password(user.email, "stalereset123")
  end

  test "reset page renders invalid token state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/users/reset_password/not-real")
    assert has_element?(view, "#reset-password-invalid")
  end
end
