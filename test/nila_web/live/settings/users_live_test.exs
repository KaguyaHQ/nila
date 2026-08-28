defmodule NilaWeb.Settings.UsersLiveTest do
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias Nila.Accounts
  alias Nila.Orgs

  describe "as an owner" do
    setup %{conn: conn} do
      %{user: owner, org: org} = user_with_org_fixture(%{user: %{name: "Owner One"}})
      %{conn: log_in_user(conn, owner), owner: owner, org: org}
    end

    test "lists members and the invite control", %{conn: conn, owner: owner} do
      {:ok, view, _html} = live(conn, ~p"/settings/users")

      assert has_element?(view, "#settings-users")
      assert has_element?(view, "#invite-user-button")
      assert has_element?(view, "#settings-users .nila-select")
      refute has_element?(view, "#settings-users .select")
      assert has_element?(view, ~s|a[aria-current="page"][href="/settings/users"]|)
      assert has_element?(view, "#members .wrap-break-word", owner.name)
      assert has_element?(view, "#members .wrap-break-word", owner.email)
      assert render(view) =~ owner.name
    end

    test "invites a new user", %{conn: conn, org: org} do
      {:ok, view, _html} = live(conn, ~p"/settings/users")

      view |> element("#invite-user-button") |> render_click()

      assert has_element?(view, "#invite-modal .nila-modal-footer > #invite-cancel")

      assert has_element?(
               view,
               "#invite-modal .nila-modal-footer > #invite-submit[form='invite-form'][type='submit']"
             )

      view
      |> form("#invite-form",
        invite: %{name: "Jaimathi", email: "jaimathi@example.com", role: "member"}
      )
      |> render_submit()

      assert render(view) =~ "Invitation sent"

      assert Enum.any?(
               Orgs.list_memberships(org.id),
               &(&1.user.email == "jaimathi@example.com" and &1.role == "member")
             )

      assert_email_sent(fn email -> assert email.text_body =~ "/users/invite/" end)
    end

    test "shows an invited user as Invited", %{conn: conn, org: org} do
      {:ok, _user} =
        Accounts.invite_user(org, %{name: "Pending Person", email: "pending@example.com"}, fn t ->
          "http://localhost/users/invite/#{t}"
        end)

      {:ok, view, _html} = live(conn, ~p"/settings/users")

      assert render(view) =~ "Pending Person"
      assert render(view) =~ "Invited"
    end

    test "changes a member's role", %{conn: conn, org: org} do
      member = user_fixture(%{name: "Member Two"})
      {:ok, membership} = Orgs.add_user(org, member.id, "member")
      {:ok, view, _html} = live(conn, ~p"/settings/users")

      view
      |> element("#role-form-#{membership.id}")
      |> render_change(%{"membership_id" => to_string(membership.id), "role" => "viewer"})

      assert Orgs.get_membership!(membership.id).role == "viewer"
    end

    test "refuses to demote the last owner", %{conn: conn, org: org, owner: owner} do
      membership = Enum.find(Orgs.list_memberships(org.id), &(&1.user_id == owner.id))
      {:ok, view, _html} = live(conn, ~p"/settings/users")

      view
      |> element("#role-form-#{membership.id}")
      |> render_change(%{"membership_id" => to_string(membership.id), "role" => "member"})

      assert render(view) =~ "last owner"
      assert Orgs.get_membership!(membership.id).role == "owner"
    end

    test "disables a member", %{conn: conn, org: org} do
      member = user_fixture(%{name: "Member Three"})
      {:ok, _membership} = Orgs.add_user(org, member.id, "member")
      {:ok, view, _html} = live(conn, ~p"/settings/users")

      view
      |> element(~s|button[phx-click="toggle_active"][phx-value-user_id="#{member.id}"]|)
      |> render_click()

      refute Accounts.get_user!(member.id).active
    end
  end

  describe "authorization" do
    test "an operator is redirected away from users settings", %{conn: conn} do
      %{user: member} = user_with_org_fixture(%{role: "member"})
      conn = log_in_user(conn, member)

      assert {:error, {:redirect, %{to: "/sales-bills"}}} = live(conn, ~p"/settings/users")
    end

    test "a logged-out visitor is redirected to log in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log_in"}}} = live(conn, ~p"/settings/users")
    end
  end
end
