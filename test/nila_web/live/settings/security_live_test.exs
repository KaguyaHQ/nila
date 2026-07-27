defmodule NilaWeb.Settings.SecurityLiveTest do
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "requires authentication", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log_in"}}} = live(conn, ~p"/settings/security")
  end

  test "renders the security forms in the settings shell", %{conn: conn} do
    %{user: user} = user_with_org_fixture()

    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/settings/security")

    assert has_element?(view, "#settings-cockpit")
    assert has_element?(view, "#settings-security")
    assert has_element?(view, "#change-password-form")
    assert has_element?(view, "#sign-out-everywhere-form")
  end

  test "password update posts through the controller", %{conn: conn} do
    %{user: user} = user_with_org_fixture()

    conn =
      conn
      |> log_in_user(user)
      |> post(~p"/settings/security/password", %{
        "password_user" => %{
          "current_password" => valid_user_password(),
          "password" => "brand new password 123",
          "password_confirmation" => "brand new password 123"
        }
      })

    assert redirected_to(conn) == ~p"/settings/security"

    assert Nila.Accounts.get_user_by_email_and_password(
             user.email,
             "brand new password 123"
           )
  end

  test "sign out everywhere revokes every session", %{conn: conn} do
    %{user: user} = user_with_org_fixture()
    other_session_token = Nila.Accounts.generate_user_session_token(user)

    assert Nila.Accounts.get_user_by_session_token(other_session_token)

    conn =
      conn
      |> log_in_user(user)
      |> post(~p"/settings/security/sessions")

    assert redirected_to(conn) == ~p"/"
    assert is_nil(Nila.Accounts.get_user_by_session_token(other_session_token))
  end
end
