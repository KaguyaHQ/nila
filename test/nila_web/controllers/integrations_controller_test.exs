defmodule NilaWeb.IntegrationsControllerTest do
  use NilaWeb.ConnCase, async: true

  import Nila.AccountsFixtures

  alias Nila.Integrations
  alias Nila.Repo

  @tenant "11111111-2222-3333-4444-555555555555"
  @mailbox "mail@bvccas.com"

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()

    %{conn: log_in_user(conn, user), org: org}
  end

  test "consent binds the tenant committed before the redirect", %{conn: conn, org: org} do
    conn =
      get(conn, ~p"/integrations/microsoft/callback", %{
        "admin_consent" => "True",
        "tenant" => @tenant,
        "state" => state(conn, org)
      })

    assert redirected_to(conn) == ~p"/settings/connectors"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Confirming the grant"

    assert connection = Integrations.first_active_connection(org.id, "microsoft")
    assert connection.tenant_id == @tenant
    assert connection.external_account_id == @mailbox
    assert connection.last_status == "pending"

    assert [%Oban.Job{worker: "Nila.Integrations.MicrosoftGrantWorker"} = job] =
             Repo.all(Oban.Job)

    assert job.args["connection_id"] == connection.id
  end

  test "a tenant other than the one we committed is refused", %{conn: conn, org: org} do
    conn =
      get(conn, ~p"/integrations/microsoft/callback", %{
        "admin_consent" => "True",
        "tenant" => "99999999-8888-7777-6666-555555555555",
        "state" => state(conn, org)
      })

    assert redirected_to(conn) == ~p"/settings/connectors"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "different Microsoft tenant"

    assert is_nil(Integrations.first_active_connection(org.id, "microsoft"))
    assert Repo.all(Oban.Job) == []
  end

  test "consent without state binds nothing", %{conn: conn, org: org} do
    conn =
      get(conn, ~p"/integrations/microsoft/callback", %{
        "admin_consent" => "True",
        "tenant" => @tenant
      })

    assert redirected_to(conn) == ~p"/settings/connectors"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "connection failed"
    assert is_nil(Integrations.first_active_connection(org.id, "microsoft"))
  end

  @tag :capture_log
  test "forged state binds nothing", %{conn: conn, org: org} do
    conn =
      get(conn, ~p"/integrations/microsoft/callback", %{
        "admin_consent" => "True",
        "tenant" => @tenant,
        "state" => "not-a-signed-token"
      })

    assert redirected_to(conn) == ~p"/settings/connectors"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "connection failed"
    assert is_nil(Integrations.first_active_connection(org.id, "microsoft"))
  end

  test "a declined consent says so", %{conn: conn, org: org} do
    conn = get(conn, ~p"/integrations/microsoft/callback", %{"error" => "access_denied"})

    assert redirected_to(conn) == ~p"/settings/connectors"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not granted"
    assert is_nil(Integrations.first_active_connection(org.id, "microsoft"))
  end

  test "connect requires the tenant and mailbox before leaving for Microsoft", %{conn: conn} do
    conn = get(conn, ~p"/integrations/microsoft/connect", %{"mailbox" => @mailbox})

    assert redirected_to(conn) == ~p"/settings/connectors"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "tenant ID"
  end

  test "connect sends the admin to Microsoft with signed state", %{conn: conn} do
    conn =
      get(conn, ~p"/integrations/microsoft/connect", %{
        "tenant_id" => @tenant,
        "mailbox" => @mailbox
      })

    assert redirect = redirected_to(conn, 302)
    assert %URI{host: "login.microsoftonline.com"} = URI.parse(redirect)
    assert URI.decode_query(URI.parse(redirect).query)["state"]
  end

  test "an unknown connector redirects instead of raising", %{conn: conn} do
    conn = get(conn, ~p"/integrations/zoho/callback")

    assert redirected_to(conn) == ~p"/settings/connectors"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Unknown connector"

    conn = get(conn, ~p"/integrations/zoho/connect")
    assert redirected_to(conn) == ~p"/settings/connectors"
  end

  defp state(_conn, org) do
    Phoenix.Token.sign(NilaWeb.Endpoint, "microsoft_consent", %{
      "org_id" => org.id,
      "tenant_id" => @tenant,
      "mailbox" => @mailbox,
      "label" => nil
    })
  end
end
