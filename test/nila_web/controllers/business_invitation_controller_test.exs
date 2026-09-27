defmodule NilaWeb.BusinessInvitationControllerTest do
  import NilaWeb.ApiContract, only: [contract_response: 2]
  use NilaWeb.ConnCase, async: true
  alias Nila.Accounts.Scope
  alias Nila.Business.Access
  alias Nila.Clients

  test "CA receives a shareable invite and business sessions cannot read firm clients", %{
    conn: conn
  } do
    %{user: user, org: org} = user_with_org_fixture()
    {:ok, client} = Clients.create_client(%{org_id: org.id, name: "Business", type: "company"})
    attrs = %{name: "Owner", email: unique_user_email()}

    assert conn
           |> log_in_user(user)
           |> post("/api/workspace/clients/invalid/business-invitation", %{invitation: attrs})
           |> contract_response(404)

    response =
      conn
      |> log_in_user(user)
      |> post("/api/workspace/clients/#{client.id}/business-invitation", %{invitation: attrs})

    assert %{"invitation_url" => url, "already_active" => false} =
             contract_response(response, 200)

    assert url =~ "/users/invite/"
    {:ok, result} = Access.invite(Scope.for_user(user), client.id, attrs)

    {:ok, business_user} =
      Nila.Accounts.accept_invite(result.user, %{password: valid_user_password()})

    business_conn = build_conn() |> log_in_user(business_user)
    assert business_conn |> get("/api/workspace/clients") |> contract_response(403)

    assert business_conn |> get("/app/clients") |> redirected_to() ==
             "/app/business/#{client.id}/invoices"

    login =
      build_conn()
      |> init_test_session(%{user_return_to: "/app/clients"})
      |> NilaWeb.UserAuth.log_in_user(business_user)

    assert redirected_to(login) == "/app/business/#{client.id}/invoices"

    {:ok, disabled} = Nila.Accounts.set_user_active(business_user, false)

    disabled_conn =
      build_conn()
      |> log_in_user(disabled)
      |> NilaWeb.UserAuth.fetch_current_scope_for_user([])

    assert is_nil(disabled_conn.assigns.current_scope)
  end
end
