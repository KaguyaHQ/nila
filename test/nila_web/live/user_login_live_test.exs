defmodule NilaWeb.UserLoginLiveTest do
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "logs in with a work email and password", %{conn: conn} do
    %{user: user} = user_with_org_fixture()

    conn =
      post(conn, ~p"/users/log_in", %{
        "user" => %{"email" => user.email, "password" => valid_user_password()}
      })

    assert redirected_to(conn) == ~p"/app/clients"
  end

  test "login opens the client's closeable sales month directly", %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Nila.Clients.create_client(%{org_id: org.id, name: "Sales client", type: "company"})

    conn =
      post(conn, ~p"/users/log_in", %{
        "user" => %{"email" => user.email, "password" => valid_user_password()}
      })

    period = Nila.Gst.Filing.Calendar.closeable_period(Date.utc_today())
    assert redirected_to(conn) == ~p"/app/gst/#{client.id}/#{period}/sales"
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

  test "renders a password visibility toggle and contact link", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/users/log_in")

    assert has_element?(view, "#user_password[type=password][autocomplete='current-password']")
    assert has_element?(view, "a[href='/contact']", "Arrange a test")
    refute has_element?(view, "a[href='/users/sign_up']")

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
