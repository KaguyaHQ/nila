defmodule NilaWeb.ProfileLiveTest do
  use NilaWeb.ConnCase

  import Phoenix.LiveViewTest

  test "renders the current user's profile", %{conn: conn} do
    %{user: user} =
      user_with_org_fixture(%{
        user: %{name: "Profile Owner", email: "profile-owner@example.com"},
        org: %{name: "Profile Test Co"},
        role: "admin"
      })

    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/profile")

    assert has_element?(view, "#profile-page")
    assert has_element?(view, "#profile-name", "Profile Owner")
    assert has_element?(view, "#profile-email", "profile-owner@example.com")
    assert has_element?(view, "#profile-workspace", "Profile Test Co")
    assert has_element?(view, "#profile-role", "Admin")
  end

  test "redirects logged-out visitors to log in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log_in"}}} = live(conn, ~p"/profile")
  end
end
