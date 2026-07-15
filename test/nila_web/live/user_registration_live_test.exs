defmodule NilaWeb.UserRegistrationLiveTest do
  use NilaWeb.ConnCase

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias Nila.Accounts
  alias Nila.Accounts.User
  alias Nila.Orgs.{Membership, Org}
  alias Nila.Repo

  test "renders signup form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/users/sign_up")

    assert has_element?(view, "#registration-form")
    assert has_element?(view, "#signup_name")
    assert has_element?(view, "#signup_email[type=email]")
    assert has_element?(view, "#signup_org_name")
    assert has_element?(view, "#signup_password[type=password][autocomplete='new-password']")
    assert has_element?(view, "#signup_password_confirmation[type=password]")
  end

  test "redirects authenticated users away from signup", %{conn: conn} do
    %{user: user} = user_with_org_fixture()

    assert {:error, {:redirect, %{to: "/today"}}} =
             conn |> log_in_user(user) |> live(~p"/users/sign_up")
  end

  test "creates firm and signs in", %{conn: conn} do
    attrs = valid_signup_attributes()

    conn = post(conn, ~p"/users/sign_up", %{"signup" => attrs})

    assert redirected_to(conn) == ~p"/today"

    assert Phoenix.Flash.get(conn.assigns.flash, :info) ==
             "Firm created. Check your email to verify your account."

    user = Accounts.get_user_by_email(attrs["email"])
    assert user.name == attrs["name"]
    assert is_nil(user.confirmed_at)
    assert Accounts.get_user_by_email_and_password(attrs["email"], attrs["password"])
    assert_email_sent(fn email -> assert email.text_body =~ "/users/confirm/" end)

    membership = Repo.get_by!(Membership, user_id: user.id)
    assert membership.role == "owner"
    assert Repo.get!(Org, membership.org_id).name == attrs["org_name"]
  end

  test "shows inline signup errors", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/users/sign_up")
    before_users = Repo.aggregate(User, :count)

    html =
      view
      |> form("#registration-form", signup: valid_signup_attributes(%{"password" => "short"}))
      |> render_submit()

    assert html =~ "should be at least 8 character"
    assert has_element?(view, "#signup_password.input-error")
    assert Repo.aggregate(User, :count) == before_users
    refute_email_sent()
  end

  test "invalid signup creates no user or org", %{conn: conn} do
    before_users = Repo.aggregate(User, :count)
    before_orgs = Repo.aggregate(Org, :count)

    conn =
      post(conn, ~p"/users/sign_up", %{
        "signup" => valid_signup_attributes(%{"password" => "short"})
      })

    assert redirected_to(conn) == ~p"/users/sign_up"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Could not create"
    assert Repo.aggregate(User, :count) == before_users
    assert Repo.aggregate(Org, :count) == before_orgs
    refute_email_sent()
  end

  test "confirmation link verifies the user", %{conn: conn} do
    %{user: user} = user_with_org_fixture()

    Accounts.deliver_user_confirmation_instructions(%{user | confirmed_at: nil}, fn token ->
      send(self(), {:confirmation_token, token})
      "http://localhost/users/confirm/#{token}"
    end)

    assert_received {:confirmation_token, token}
    conn = get(conn, ~p"/users/confirm/#{token}")

    assert redirected_to(conn) == ~p"/users/log_in"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Email verified."
    assert Accounts.get_user!(user.id).confirmed_at
  end

  test "resend sends a verification email", %{conn: conn} do
    {:ok, %{user: user}} = Accounts.register_user_with_org(valid_signup_attributes())

    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/users/confirm")

    assert view |> element("#verify-email-page form") |> render_submit()
    assert_email_sent(to: [{nil, user.email}])
    assert render(view) =~ "Verification email sent to #{user.email}."
  end

  test "unverified users are gated from app pages", %{conn: conn} do
    {:ok, %{user: user}} = Accounts.register_user_with_org(valid_signup_attributes())

    assert {:error,
            {:redirect, %{to: "/users/confirm", flash: %{"error" => "Verify your email first."}}}} =
             conn |> log_in_user(user) |> live(~p"/today")

    conn = conn |> recycle() |> log_in_user(user) |> get(~p"/settings")

    assert redirected_to(conn) == ~p"/users/confirm"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Verify your email first."
  end

  defp valid_signup_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      "name" => "Signup User",
      "email" => unique_user_email(),
      "password" => valid_user_password(),
      "password_confirmation" => valid_user_password(),
      "org_name" => "Signup Org #{System.unique_integer([:positive])}"
    })
  end
end
