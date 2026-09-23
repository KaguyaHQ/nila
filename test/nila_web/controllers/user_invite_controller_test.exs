defmodule NilaWeb.UserInviteControllerTest do
  use NilaWeb.ConnCase, async: true

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

      response = get(conn, ~p"/users/invite/#{token}")
      assert response.assigns.auth_page.valid
      assert response.assigns.auth_page.name == "Jaimathi"
      assert response.assigns.auth_page.kind == "invite"
      assert html_response(response, 200) =~ "auth-page"
    end

    test "shows an invalid-link message for a bad token", %{conn: conn} do
      response = get(conn, ~p"/users/invite/garbage")
      refute response.assigns.auth_page.valid
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

      assert redirected_to(conn) == ~p"/app/clients"
      assert get_session(conn, :user_token)
      assert Accounts.get_user_by_email_and_password("kannan@example.com", "supersecret123")
    end

    test "rejects a weak password with field errors", %{conn: conn, org: org} do
      token = invite(org, %{name: "Weak", email: "weak@example.com"})

      conn =
        post(conn, ~p"/users/invite/#{token}", %{
          "user" => %{"password" => "short", "password_confirmation" => "short"}
        })

      assert conn.status == 422
      assert conn.assigns.auth_page.errors.password != []
      refute get_session(conn, :user_token)
    end
  end
end
