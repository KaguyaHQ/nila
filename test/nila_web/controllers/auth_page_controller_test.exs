defmodule NilaWeb.AuthPageControllerTest do
  use NilaWeb.ConnCase, async: true
  import Swoosh.TestAssertions
  alias Nila.Accounts

  defp page(conn, status \\ 200) do
    html = html_response(conn, status)

    [_, json] =
      Regex.run(~r/<script id="auth-page" type="application\/json">(.*?)<\/script>/s, html)

    Jason.decode!(json)
  end

  test "login renders React without dev accounts and preserves safe errors", %{conn: conn} do
    data = conn |> get("/users/log_in") |> page()
    assert data["kind"] == "login"
    assert data["users"] == []
    email = "</script><script>alert(1)</script>@example.com"
    failed = post(conn, "/users/log_in", %{user: %{email: email, password: "wrong"}})
    assert redirected_to(failed) == "/users/log_in"
    rendered = failed |> recycle() |> get("/users/log_in")
    assert page(rendered)["email"] == email
    refute html_response(rendered, 200) =~ "<script>alert(1)"
    assert get_resp_header(rendered, "cache-control") == ["no-store"]
    assert get_resp_header(rendered, "referrer-policy") == ["no-referrer"]
  end

  test "password login preserves session, remember cookie and explicit return", %{conn: conn} do
    %{user: user} = user_with_org_fixture()

    conn =
      conn
      |> init_test_session(%{user_return_to: "/app/notices"})
      |> post("/users/log_in", %{
        user: %{email: user.email, password: valid_user_password(), remember_me: "true"}
      })

    assert redirected_to(conn) == "/app/notices"
    assert get_session(conn, :user_token)
    assert conn.resp_cookies["_nila_web_user_remember_me"]
  end

  test "signup stays invite-only and dev login is unavailable", %{conn: conn} do
    assert conn |> get("/users/sign_up") |> redirected_to() == "/contact"
    %{user: user} = user_with_org_fixture()
    denied = post(conn, "/users/log_in", %{dev_login: "true", email: user.email})
    assert redirected_to(denied) == "/users/log_in"
    refute get_session(denied, :user_token)
  end

  test "reset request does not reveal whether account exists", %{conn: conn} do
    user = user_fixture()

    for email <- [user.email, "missing@example.com"] do
      response = post(conn, "/users/reset_password", %{user: %{email: email}})
      assert redirected_to(response) == "/users/log_in"

      assert Phoenix.Flash.get(response.assigns.flash, :info) ==
               "If your email exists in Nila, password reset instructions have been sent."
    end

    assert_email_sent(to: [{nil, user.email}])
  end

  test "reset validates password, revokes sessions and rejects a consumed token", %{conn: conn} do
    user = user_fixture()
    session_token = Accounts.generate_user_session_token(user)

    Accounts.deliver_user_reset_password_instructions(user.email, fn token ->
      send(self(), {:token, token})
      "http://localhost/users/reset_password/#{token}"
    end)

    assert_received {:token, token}
    path = "/users/reset_password/#{token}"
    assert conn |> get(path) |> page() |> Map.get("valid")
    invalid = post(conn, path, %{user: %{password: "short", password_confirmation: "other"}})
    assert page(invalid, 422)["errors"]["password"] != []
    refute html_response(invalid, 422) =~ "\"password\":\"short\""

    saved =
      post(conn, path, %{
        user: %{password: "newpassword123", password_confirmation: "newpassword123"}
      })

    assert redirected_to(saved) == "/users/log_in"
    assert Accounts.get_user_by_email_and_password(user.email, "newpassword123")
    refute Accounts.get_user_by_session_token(session_token)

    rejected =
      post(conn, path, %{
        user: %{password: "anotherpass123", password_confirmation: "anotherpass123"}
      })

    refute page(rejected, 422)["valid"]
    refute conn |> get("/users/reset_password/not-real") |> page() |> Map.get("valid")
  end

  test "confirmation requires login, sends mail and consumes verification link", %{conn: conn} do
    assert conn |> get("/users/confirm") |> redirected_to() == "/users/log_in"
    %{user: user} = user_with_org_fixture()
    user = user |> Ecto.Changeset.change(confirmed_at: nil) |> Nila.Repo.update!()
    logged = log_in_user(conn, user)
    refute logged |> get("/users/confirm") |> page() |> Map.get("confirmed")
    assert logged |> get("/app/clients") |> redirected_to() == "/users/confirm"
    assert logged |> post("/users/confirm") |> redirected_to() == "/users/confirm"
    assert_email_sent(to: [{nil, user.email}])

    Accounts.deliver_user_confirmation_instructions(user, fn token ->
      send(self(), {:token, token})
      "http://localhost/users/confirm/#{token}"
    end)

    assert_received {:token, token}
    assert logged |> get("/users/confirm/#{token}") |> redirected_to() == "/users/confirm"
    assert logged |> get("/users/confirm") |> page() |> Map.get("confirmed")
    assert Accounts.get_user!(user.id).confirmed_at
  end
end
