defmodule NilaWeb.BusinessRegistrationControllerTest do
  use NilaWeb.ConnCase, async: true
  import Swoosh.TestAssertions
  alias Nila.Accounts

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
