defmodule NilaWeb.IntegrationsControllerTest do
  use NilaWeb.ConnCase, async: true

  import Nila.AccountsFixtures

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()

    %{conn: log_in_user(conn, user), org: org}
  end

  test "the Microsoft consent redirect lands without crashing", %{conn: conn} do
    conn =
      get(conn, ~p"/integrations/microsoft/callback", %{
        "admin_consent" => "True",
        "tenant" => "11111111-2222-3333-4444-555555555555"
      })

    assert redirected_to(conn) == ~p"/settings/connectors"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "consent granted"
  end

  test "a declined Microsoft consent says so", %{conn: conn} do
    conn = get(conn, ~p"/integrations/microsoft/callback", %{"error" => "access_denied"})

    assert redirected_to(conn) == ~p"/settings/connectors"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "not granted"
  end

  test "an unknown connector redirects instead of raising", %{conn: conn} do
    conn = get(conn, ~p"/integrations/zoho/callback")

    assert redirected_to(conn) == ~p"/settings/connectors"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Unknown connector"

    conn = get(conn, ~p"/integrations/zoho/connect")
    assert redirected_to(conn) == ~p"/settings/connectors"
  end
end
