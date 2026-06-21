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

    test "renders workspace stub in the settings shell", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/workspace")

      assert has_element?(view, "#app-shell")
      assert has_element?(view, "#settings-cockpit")
      assert has_element?(view, "#settings-nav")
      assert has_element?(view, "#settings-workspace")
      assert has_element?(view, "#settings-entity-list")
      assert has_element?(view, "#settings-entity-form")
      assert has_element?(view, ~s|a[aria-current="page"][href="/settings/workspace"]|)
    end

    test "updates and creates legal entities", %{conn: conn, org: org} do
      {:ok, view, _html} = live(conn, ~p"/settings/workspace")

      view
      |> form("#settings-entity-form",
        entity: %{
          name: "Caltech Refrigeration",
          gstin: "33BPBPK1081A1ZO",
          state: "Tamil Nadu",
          contact_email: "kannancaltech@gmail.com",
          contact_phone: "9962550448",
          bank_account_holder: "Caltech Refrigeration",
          bank_account_number: "1234567890",
          bank_ifsc: "HDFC0001234",
          bank_name: "HDFC Bank",
          invoice_prefix: "",
          invoice_next: "30",
          invoice_padding: "0"
        }
      )
      |> render_submit()

      assert [caltech] = Orgs.list_entities(org.id)
      assert caltech.name == "Caltech Refrigeration"
      assert caltech.invoice_next == 30

      view |> element("#settings-new-entity") |> render_click()

      view
      |> form("#settings-entity-form",
        entity: %{
          name: "Breezetech Services",
          gstin: "33ABCDE1234F1Z7",
          state: "Tamil Nadu",
          invoice_prefix: "BT-",
          invoice_next: "7",
          invoice_padding: "3"
        }
      )
      |> render_submit()

      assert Enum.map(Orgs.list_entities(org.id), & &1.name) == [
               "Breezetech Services",
               "Caltech Refrigeration"
             ]
    end

    test "renders the connectors stub", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/connectors")

      assert has_element?(view, "#settings-connectors")
    end

    test "manages connector labels, entities, disconnect, reconnect, and sync", %{
      conn: conn,
      org: org
    } do
      entity = Orgs.get_or_create_default_entity!(org.id)

      {:ok, connection} =
        Integrations.upsert_connection(%{
          org_id: org.id,
          entity_id: entity.id,
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
        connection: %{label: "GRN tracking", entity_id: entity.id}
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
