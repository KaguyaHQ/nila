defmodule NilaWeb.SettingsLiveTest do
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Nila.Integrations
  alias Nila.Orgs
  alias Nila.Repo

  describe "settings shell" do
    setup %{conn: conn} do
      %{user: user, org: org} = user_with_org_fixture()

      {:ok, conn: log_in_user(conn, user), org: org}
    end

    test "offers a Microsoft consent form on the connectors screen", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/connectors")

      assert has_element?(view, "#settings-add-microsoft-form")
      assert has_element?(view, "#settings-add-microsoft-tenant")
      assert has_element?(view, "#settings-add-microsoft-mailbox")

      assert has_element?(
               view,
               ~s|form#settings-add-microsoft-form[action="/integrations/microsoft/connect"]|
             )
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

    test "renders Meta Embedded Signup on the connectors screen", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/connectors")

      assert has_element?(view, "#settings-connectors[phx-hook='WhatsAppEmbeddedSignup']")
      assert has_element?(view, "#settings-connect-whatsapp[data-whatsapp-launch]")
    end

    test "connects WhatsApp once with a signed, one-use transaction", %{conn: conn, org: org} do
      {:ok, view, _html} = live(conn, ~p"/settings/connectors")
      transaction = whatsapp_transaction(view)

      payload = %{
        "authorization_code" => "valid-code",
        "transaction" => transaction,
        "session" => %{
          "business_id" => "111111111",
          "waba_id" => "222222222",
          "phone_number_id" => "333333333"
        }
      }

      render_hook(view, "whatsapp_signup_complete", payload)
      assert_reply(view, %{ok: true})

      assert [connection] = Integrations.list_connections(org.id)
      assert connection.provider == "whatsapp"
      assert connection.external_account_id == "333333333"
      assert connection.settings["waba_id"] == "222222222"

      render_hook(view, "whatsapp_signup_complete", payload)
      assert_reply(view, %{ok: false})
      assert [_connection] = Integrations.list_connections(org.id)
    end

    test "rejects a forged WhatsApp signup transaction", %{conn: conn, org: org} do
      {:ok, view, _html} = live(conn, ~p"/settings/connectors")
      original_transaction = whatsapp_transaction(view)

      render_hook(view, "whatsapp_signup_complete", %{
        "authorization_code" => "valid-code",
        "transaction" => "forged",
        "session" => %{
          "business_id" => "111111111",
          "waba_id" => "222222222",
          "phone_number_id" => "333333333"
        }
      })

      assert_reply(view, %{ok: false})
      refute whatsapp_transaction(view) == original_transaction
      assert Integrations.list_connections(org.id) == []
    end

    test "WhatsApp disconnect requires fresh Meta signup and hides mailbox sync", %{
      conn: conn,
      org: org
    } do
      {:ok, connection} =
        Integrations.complete_whatsapp_signup(org.id, "valid-code", %{
          "business_id" => "111111111",
          "waba_id" => "222222222",
          "phone_number_id" => "333333333"
        })

      {:ok, view, _html} = live(conn, ~p"/settings/connectors")

      refute has_element?(view, "#settings-sync-connection-#{connection.id}")
      assert has_element?(view, "#settings-verify-connection-#{connection.id}")

      view |> element("#settings-verify-connection-#{connection.id}") |> render_click()
      assert Repo.get!(Integrations.Connection, connection.id).last_status == "connected"

      view |> element("#settings-disconnect-connection-#{connection.id}") |> render_click()
      disconnected = Repo.get!(Integrations.Connection, connection.id)
      assert disconnected.status == "disconnected"
      assert disconnected.credentials == %{}

      assert has_element?(
               view,
               "#settings-reconnect-connection-#{connection.id}[data-whatsapp-launch]"
             )

      render_hook(view, "whatsapp_signup_complete", %{
        "authorization_code" => "valid-code",
        "connection_id" => Integer.to_string(connection.id),
        "transaction" => whatsapp_transaction(view),
        "session" => %{
          "business_id" => "111111111",
          "waba_id" => "222222222",
          "phone_number_id" => "444444444"
        }
      })

      assert_reply(view, %{ok: false})
      assert [same_connection] = Integrations.list_connections(org.id)
      assert same_connection.id == connection.id
      assert same_connection.status == "disconnected"
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

      view |> element("#settings-disconnect-connection-#{connection.id}") |> render_click()
      assert Repo.get!(Integrations.Connection, connection.id).status == "disconnected"

      view |> element("#settings-reconnect-connection-#{connection.id}") |> render_click()
      assert Repo.get!(Integrations.Connection, connection.id).status == "active"
    end
  end

  defp whatsapp_transaction(view) do
    [transaction] =
      ~r/data-transaction="([^"]+)"/
      |> Regex.run(render(view), capture: :all_but_first)

    transaction
  end

  test "redirects unauthenticated settings visits to login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log_in"}}} = live(conn, ~p"/settings/workspace")
  end
end
