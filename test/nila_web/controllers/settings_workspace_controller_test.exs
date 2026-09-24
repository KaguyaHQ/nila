defmodule NilaWeb.SettingsWorkspaceControllerTest do
  use NilaWeb.ConnCase, async: true
  import NilaWeb.ApiContract, only: [contract_response: 2, contract_response: 3]
  alias Nila.{Accounts, Orgs, Repo}
  @base "/api/workspace/settings"

  setup %{conn: conn} do
    %{user: user, org: org, membership: membership} = user_with_org_fixture()
    %{conn: log_in_user(conn, user), user: user, org: org, membership: membership}
  end

  test "snapshot exposes permitted settings, never password hashes", %{conn: conn, user: user} do
    response = get(conn, @base)
    body = contract_response(response, 200)
    assert body["user"]["id"] == user.id
    assert body["can_manage_firm"]

    assert [%{"self" => true, "can_change_role" => false, "can_toggle_active" => false}] =
             body["members"]

    refute response.resp_body =~ "hashed_password"
    assert get_resp_header(response, "cache-control") == ["private, no-store"]
  end

  test "name allows no account privilege or email changes and returns errors", %{
    conn: conn,
    user: user
  } do
    assert conn |> patch(@base <> "/name", %{name: ""}) |> contract_response(422)

    assert conn
           |> patch(@base <> "/name", %{
             name: "New name",
             active: false,
             email: "injected@example.com"
           })
           |> contract_response(200, request: false)

    saved = Repo.reload!(user)
    assert saved.name == "New name"
    assert saved.email == user.email
    assert saved.active
  end

  test "viewer can change own profile but cannot edit firm or users", %{conn: conn} do
    %{user: viewer} = user_with_org_fixture(%{role: "viewer"})
    conn = log_in_user(conn, viewer)
    body = conn |> get(@base) |> contract_response(200)
    refute body["can_manage_firm"]
    assert body["members"] == []

    assert conn
           |> patch(@base <> "/firm", %{name: "Injected", contact_phone: ""})
           |> contract_response(403)

    assert conn
           |> post(@base <> "/invitations", %{name: "Injected", email: "a@b.test", role: "owner"})
           |> contract_response(403)

    assert conn |> patch(@base <> "/name", %{name: "Viewer name"}) |> contract_response(200)
  end

  test "password errors keep old session; success renews it and revokes other sessions", %{
    conn: conn,
    user: user
  } do
    old = get_session(conn, :user_token)
    other = Accounts.generate_user_session_token(user)

    bad =
      post(conn, @base <> "/password", %{
        current_password: "wrong",
        password: "newpassword123",
        password_confirmation: "newpassword123"
      })

    assert contract_response(bad, 422)["fields"]["current_password"]
    assert Accounts.get_user_by_session_token(old)

    result =
      post(conn, @base <> "/password", %{
        current_password: valid_user_password(),
        password: "newpassword123",
        password_confirmation: "newpassword123"
      })

    assert contract_response(result, 200)["redirect_to"] ==
             "/app/settings/security?updated=password"

    assert get_session(result, :user_token) != old
    refute Accounts.get_user_by_session_token(old)
    refute Accounts.get_user_by_session_token(other)
    assert Accounts.get_user_by_session_token(get_session(result, :user_token))
  end

  test "sign out everywhere revokes all sessions and clears the browser session", %{
    conn: conn,
    user: user
  } do
    token = Accounts.generate_user_session_token(user)
    result = post(conn, @base <> "/sessions")
    assert contract_response(result, 200)["redirect_to"] == "/users/log_in"
    refute get_session(result, :user_token)
    refute Accounts.get_user_by_session_token(token)
    login = result |> recycle() |> get("/users/log_in")
    assert html_response(login, 200) =~ "Signed out everywhere."

    refute login |> recycle() |> get("/users/log_in") |> html_response(200) =~
             "Signed out everywhere."
  end

  test "email requires password and stays unchanged until confirmation", %{conn: conn, user: user} do
    assert conn
           |> post(@base <> "/email", %{email: "new@example.test", current_password: "wrong"})
           |> contract_response(422)

    assert conn
           |> post(@base <> "/email", %{
             email: "new@example.test",
             current_password: valid_user_password()
           })
           |> contract_response(200)

    assert Repo.reload!(user).email == user.email
  end

  test "member actions are firm scoped and protect self and last owner", %{
    conn: conn,
    membership: membership
  } do
    %{membership: other} = user_with_org_fixture()

    assert conn
           |> patch(@base <> "/members/#{other.id}", %{action: "active", active: false})
           |> contract_response(404)

    assert conn
           |> patch(@base <> "/members/#{membership.id}", %{action: "active", active: false})
           |> contract_response(422)

    assert conn
           |> patch(@base <> "/members/#{membership.id}", %{action: "role", role: "viewer"})
           |> contract_response(422)
  end

  test "firm updates and invitations reuse existing domain behavior", %{conn: conn, org: org} do
    assert conn
           |> patch(@base <> "/firm", %{name: "Changed firm", contact_phone: "1234567890"})
           |> contract_response(200)

    assert Orgs.get_org!(org.id).name == "Changed firm"
    email = unique_user_email()

    assert conn
           |> post(@base <> "/invitations", %{name: "New colleague", email: email, role: "viewer"})
           |> contract_response(200)

    member = Enum.find(Orgs.list_memberships(org.id), &(&1.user.email == email))
    assert member.role == "viewer"

    assert conn
           |> patch(@base <> "/members/#{member.id}", %{action: "resend"})
           |> contract_response(200)

    assert conn
           |> patch(@base <> "/members/#{member.id}", %{action: "role", role: "member"})
           |> contract_response(200)

    assert conn
           |> patch(@base <> "/members/#{member.id}", %{action: "active", active: false})
           |> contract_response(200)

    refute Repo.reload!(member.user).active
  end

  test "unauthenticated settings requests are rejected" do
    assert build_conn() |> get(@base) |> contract_response(401)
  end
end
