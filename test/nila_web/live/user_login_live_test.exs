defmodule NilaWeb.UserLoginLiveTest do
  use NilaWeb.ConnCase

  import Phoenix.LiveViewTest

  test "logs in with a work email and password", %{conn: conn} do
    %{user: user} = user_with_org_fixture()

    conn =
      post(conn, ~p"/users/log_in", %{
        "user" => %{"email" => user.email, "password" => valid_user_password()}
      })

    assert redirected_to(conn) == ~p"/today"
  end

  test "rejects the wrong password", %{conn: conn} do
    %{user: user} = user_with_org_fixture()

    conn =
      post(conn, ~p"/users/log_in", %{
        "user" => %{"email" => user.email, "password" => "wrong-password"}
      })

    assert redirected_to(conn) == ~p"/users/log_in"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password."
  end

  test "renders a password visibility toggle and signup link", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/users/log_in")

    assert has_element?(view, "#user_password[type=password][autocomplete='current-password']")
    assert has_element?(view, "a[href='/users/sign_up']", "Create a firm")

    assert has_element?(
             view,
             "#user_password-toggle[aria-label='Show password'][aria-controls='user_password'][aria-pressed='false'][type='button']"
           )
  end

  test "does not render quick login buttons or allow dev login in test", %{conn: conn} do
    %{user: user} = user_with_org_fixture()

    {:ok, view, _html} = live(conn, ~p"/users/log_in")

    refute render(view) =~ "Quick login"
    refute render(view) =~ user.name

    conn = post(conn, ~p"/users/log_in", %{"dev_login" => "true", "email" => user.email})
    assert redirected_to(conn) == ~p"/users/log_in"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password."
  end
end
