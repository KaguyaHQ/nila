defmodule NilaWeb.BusinessRegistrationControllerTest do
  use NilaWeb.ConnCase, async: true
  import Swoosh.TestAssertions
  alias Nila.Accounts
  alias Nila.Business.Access

  defp attrs(email \\ "new-business@example.com") do
    %{
      "user" => %{
        "name" => "New owner",
        "email" => email,
        "password" => "safe-password-123",
        "password_confirmation" => "safe-password-123"
      },
      "business" => %{"name" => "New Studio", "gstin" => "27AAPFU0939F1ZV"}
    }
  end

  test "business signup page is public and the old signup path reaches it", %{conn: conn} do
    assert get(conn, "/users/business_sign_up") |> html_response(200) =~ "business_signup"
    assert get(build_conn(), "/users/sign_up") |> redirected_to() == "/users/business_sign_up"
  end

  test "signup confirms email, logs in, and redirects to verification", %{conn: conn} do
    conn = post(conn, "/users/business_sign_up", attrs())
    assert redirected_to(conn) == "/users/confirm"
    assert get_session(conn, :user_token)
    assert Accounts.get_user_by_email("new-business@example.com").confirmed_at == nil
    assert_email_sent()

    conn = recycle(conn) |> get("/users/confirm")
    assert html_response(conn, 200) =~ "new-business@example.com"
  end

  test "signed-in firm user creates a business with the same login", %{conn: conn} do
    %{user: firm_user} = user_with_org_fixture()
    conn = log_in_user(conn, firm_user)

    signup = get(conn, "/users/business_sign_up") |> html_response(200)
    assert signup =~ "business_signup"
    assert signup =~ firm_user.email

    created = post(conn, "/users/business_sign_up", attrs())
    [client] = Access.list_clients_for_user(firm_user.id)

    assert redirected_to(created) == "/app/business/#{client.id}/invoices"

    assert Accounts.get_user_by_session_token(get_session(created, :user_token)).id ==
             firm_user.id

    refute Accounts.get_user_by_email("new-business@example.com")
  end

  test "signed-in user adds a business from the workspace switcher", %{conn: conn} do
    %{user: user} = user_with_org_fixture()
    conn = log_in_user(conn, user)

    created =
      conn
      |> put_req_header("accept", "application/json")
      |> post("/api/business/workspaces", %{
        "business" => %{"name" => "Caltech", "gstin" => "27AAPFU0939F1ZV"}
      })

    %{"business" => %{"id" => id, "name" => "Caltech", "gstin" => "27AAPFU0939F1ZV"}} =
      json_response(created, 201)

    assert Enum.any?(Access.list_clients_for_user(user.id), &(&1.id == id))

    invalid =
      conn
      |> put_req_header("accept", "application/json")
      |> post("/api/business/workspaces", %{
        "business" => %{"name" => "Another", "gstin" => "invalid"}
      })

    assert %{"errors" => %{"gstin" => _}} = json_response(invalid, 422)
  end

  test "business creation API requires sign-in", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> post("/api/business/workspaces", %{
        "business" => %{"name" => "Caltech", "gstin" => "27AAPFU0939F1ZV"}
      })

    assert json_response(conn, 401)["error"] == "Sign in to continue."
  end

  test "invalid GSTIN and duplicate email render signup errors without creating rows", %{
    conn: conn
  } do
    bad = put_in(attrs(), ["business", "gstin"], "invalid")
    response = conn |> post("/users/business_sign_up", bad) |> html_response(422)
    assert response =~ "business_signup"
    refute Accounts.get_user_by_email("new-business@example.com")

    %{user: existing} = Nila.AccountsFixtures.user_with_org_fixture()
    duplicate = put_in(attrs(), ["user", "email"], existing.email)
    response = build_conn() |> post("/users/business_sign_up", duplicate) |> html_response(422)
    assert response =~ "business_signup"
    assert Accounts.get_user_by_email(existing.email).id == existing.id
  end
end
