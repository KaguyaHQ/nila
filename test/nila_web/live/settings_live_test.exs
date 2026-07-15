defmodule NilaWeb.SettingsLiveTest do
  use NilaWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Nila.Integrations
  alias Nila.Orgs
  alias Nila.Repo

  describe "settings shell" do
    setup %{conn: conn} do
      %{user: user, org: org} = user_with_org_fixture()

      {:ok, conn: log_in_user(conn, user), org: org}
    end

    test "redirects /settings to workspace settings", %{conn: conn} do
      conn = get(conn, ~p"/settings")

      assert redirected_to(conn) == ~p"/settings/workspace"
    end

    test "renders the firm settings form in the settings shell", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/workspace")

      assert has_element?(view, "#app-shell")
      assert has_element?(view, "#settings-cockpit")
      assert has_element?(view, "#settings-nav")
      assert has_element?(view, "#settings-workspace")
      assert has_element?(view, "#settings-firm-form")
      assert has_element?(view, ~s|a[aria-current="page"][href="/settings/workspace"]|)
    end

    test "updates the firm's filing identity", %{conn: conn, org: org} do
      {:ok, view, _html} = live(conn, ~p"/settings/workspace")

      view
      |> form("#settings-firm-form",
        org: %{
          name: "Balaji & Associates",
          legal_name: "Balaji and Associates LLP",
          gstin: "33BPBPK1081A1ZO",
          state: "Tamil Nadu",
          contact_email: "balaji@example.com",
          contact_phone: "9962550448",
          address_line1: "No 1 Marina",
          city: "Chennai",
          postal_code: "600001"
        }
      )
      |> render_submit()

      firm = Orgs.get_org!(org.id)
      assert firm.name == "Balaji & Associates"
      assert firm.legal_name == "Balaji and Associates LLP"
      assert firm.gstin == "33BPBPK1081A1ZO"
      assert firm.city == "Chennai"
    end

    test "renders the connectors stub", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/connectors")

      assert has_element?(view, "#settings-connectors")
    end

    test "manages connector labels, entities, disconnect, reconnect, and sync", %{
      conn: conn,
      org: org
    } do
      {:ok, connection} =
        Integrations.upsert_connection(%{
          org_id: org.id,
          label: "Caltech invoices",
          provider: "gmail",
          status: "active",
          external_account_id: "caltech@example.com",
          credentials: %{"access_token" => "token"}
        })

      {:ok, view, _html} = live(conn, ~p"/settings/connectors")

      assert has_element?(view, "#settings-connection-#{connection.id}")
      assert has_element?(view, "#settings-add-gmail-form")

      view
      |> form("#settings-connection-form-#{connection.id}",
        connection: %{label: "GRN tracking"}
      )
      |> render_submit()

      assert Repo.get!(Integrations.Connection, connection.id).label == "GRN tracking"

      view |> element("#settings-sync-connection-#{connection.id}") |> render_click()

      assert [%Oban.Job{worker: "Nila.Integrations.GmailSyncWorker"} = job] =
               Repo.all(Oban.Job)

      assert job.args["connection_id"] == connection.id

      view |> element("#settings-disconnect-connection-#{connection.id}") |> render_click()
      assert Repo.get!(Integrations.Connection, connection.id).status == "disconnected"

      view |> element("#settings-reconnect-connection-#{connection.id}") |> render_click()
      assert Repo.get!(Integrations.Connection, connection.id).status == "active"
    end
  end

  test "redirects unauthenticated settings visits to login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log_in"}}} = live(conn, ~p"/settings/workspace")
  end
end
