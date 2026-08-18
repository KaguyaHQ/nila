defmodule NilaWeb.Settings.ProfileLiveTest do
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias Nila.Accounts

  defp email_url_fun(test_pid \\ self()) do
    fn token ->
      send(test_pid, {:change_email_token, token})
      "http://localhost/settings/profile/confirm_email/#{token}"
    end
  end

  test "requires authentication", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log_in"}}} = live(conn, ~p"/settings/profile")
  end

  test "renders the current user's profile in the settings shell", %{conn: conn} do
    %{user: user} =
      user_with_org_fixture(%{
        user: %{name: "Profile Owner", email: "profile-owner@example.com"},
        org: %{name: "Profile Test Co"},
        role: "admin"
      })

    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/settings/profile")

    assert has_element?(view, "#settings-cockpit")
    assert has_element?(view, "#settings-profile")
    assert has_element?(view, "#profile-name.wrap-break-word:not(.truncate)", "Profile Owner")

    assert has_element?(
             view,
             "#profile-email.wrap-break-word:not(.truncate)",
             "profile-owner@example.com"
           )

    assert has_element?(view, "#profile-workspace", "Profile Test Co")
    assert has_element?(view, "#profile-role", "Admin")
    assert has_element?(view, "#change-email-form")
  end

  test "member without manage_settings sees account nav but no firm nav", %{conn: conn} do
    %{user: user} = user_with_org_fixture(%{role: "member"})

    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/settings/profile")

    assert has_element?(view, ~s|#settings-nav a[href="/settings/security"]|)
    refute has_element?(view, ~s|#settings-nav a[href="/settings/workspace"]|)
  end

  test "name change updates the user and the profile card", %{conn: conn} do
    %{user: user} = user_with_org_fixture(%{user: %{name: "Old Name"}})

    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/settings/profile")

    view
    |> form("#change-name-form", name_user: %{name: "New Name"})
    |> render_submit()

    assert has_element?(view, "#profile-name", "New Name")
    assert Nila.Repo.get!(Nila.Accounts.User, user.id).name == "New Name"
  end

  test "name change rejects a blank name", %{conn: conn} do
    %{user: user} = user_with_org_fixture(%{user: %{name: "Kept Name"}})

    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/settings/profile")

    view
    |> form("#change-name-form", name_user: %{name: ""})
    |> render_submit()

    assert has_element?(view, "#change-name-form", "can't be blank")
    assert Nila.Repo.get!(Nila.Accounts.User, user.id).name == "Kept Name"
  end

  test "email change form sends confirmation to new address", %{conn: conn} do
    %{user: user} = user_with_org_fixture()

    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/settings/profile")

    view
    |> form("#change-email-form",
      email_user: %{email: "new-live@example.com", current_password: valid_user_password()}
    )
    |> render_submit()

    assert_email_sent(to: [{nil, "new-live@example.com"}])
  end

  test "confirm email link applies change", %{conn: conn} do
    %{user: user} = user_with_org_fixture()

    assert {:ok, _email} =
             Accounts.deliver_user_update_email_instructions(
               user,
               valid_user_password(),
               %{"email" => "confirmed-live@example.com"},
               email_url_fun()
             )

    assert_received {:change_email_token, token}

    assert {:error, {:live_redirect, %{to: "/settings/profile"}}} =
             conn |> log_in_user(user) |> live(~p"/settings/profile/confirm_email/#{token}")

    assert Accounts.get_user_by_email("confirmed-live@example.com")
  end
end
