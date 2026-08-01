defmodule NilaWeb.UserConfirmationLiveTest do
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias Nila.Accounts
  alias Nila.Repo

  setup do
    %{user: user} = user_with_org_fixture()
    user = user |> Ecto.Changeset.change(confirmed_at: nil) |> Repo.update!()
    %{user: user}
  end

  test "confirmation link verifies the user", %{conn: conn, user: user} do
    Accounts.deliver_user_confirmation_instructions(user, fn token ->
      send(self(), {:confirmation_token, token})
      "http://localhost/users/confirm/#{token}"
    end)

    assert_received {:confirmation_token, token}
    conn = get(conn, ~p"/users/confirm/#{token}")

    assert redirected_to(conn) == ~p"/users/log_in"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Email verified."
    assert Accounts.get_user!(user.id).confirmed_at
  end

  test "resend sends a verification email", %{conn: conn, user: user} do
    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/users/confirm")

    assert view |> element("#verify-email-page form") |> render_submit()
    assert_email_sent(to: [{nil, user.email}])
    assert render(view) =~ "Verification email sent to #{user.email}."
  end

  test "unverified users are gated from app pages", %{conn: conn, user: user} do
    assert {:error,
            {:redirect, %{to: "/users/confirm", flash: %{"error" => "Verify your email first."}}}} =
             conn |> log_in_user(user) |> live(~p"/today")

    conn = conn |> recycle() |> log_in_user(user) |> get(~p"/settings")

    assert redirected_to(conn) == ~p"/users/confirm"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Verify your email first."
  end
end
