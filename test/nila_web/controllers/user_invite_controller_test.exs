defmodule NilaWeb.UserInviteControllerTest do
  use NilaWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Nila.Accounts

  defp invite(org, attrs) do
    test_pid = self()

    {:ok, _user} =
      Accounts.invite_user(org, attrs, fn token ->
        send(test_pid, {:invite_token, token})
        "http://localhost/users/invite/#{token}"
      end)

    assert_received {:invite_token, token}
    token
  end

  setup do
    %{org: org_fixture()}
  end

  describe "GET /users/invite/:token" do
    test "renders the set-password form for a valid token", %{conn: conn, org: org} do
      token = invite(org, %{name: "Jaimathi", email: "jaimathi@example.com"})

      {:ok, _view, html} = live(conn, ~p"/users/invite/#{token}")

      assert html =~ "Welcome, Jaimathi"
      assert html =~ "Create a password"
    end

    test "shows an invalid-link message for a bad token", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/users/invite/garbage")

      assert html =~ "no longer valid"
    end
  end

  describe "POST /users/invite/:token" do
    test "sets the password and signs the user in", %{conn: conn, org: org} do
      token = invite(org, %{name: "Kannan", email: "kannan@example.com"})

      conn =
        post(conn, ~p"/users/invite/#{token}", %{
          "user" => %{
            "password" => "supersecret123",
            "password_confirmation" => "supersecret123"
          }
        })

      assert redirected_to(conn) == ~p"/today"
      assert get_session(conn, :user_token)
      assert Accounts.get_user_by_email_and_password("kannan@example.com", "supersecret123")
    end

    test "rejects a weak password and redirects back", %{conn: conn, org: org} do
      token = invite(org, %{name: "Weak", email: "weak@example.com"})

      conn =
        post(conn, ~p"/users/invite/#{token}", %{
          "user" => %{"password" => "short", "password_confirmation" => "short"}
        })

      assert redirected_to(conn) == ~p"/users/invite/#{token}"
      refute get_session(conn, :user_token)
    end
  end
end
