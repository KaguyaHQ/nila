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

    test "shows the accounting connector while document intake is hidden", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/connectors")

      refute has_element?(view, "#settings-connected-accounts")

      assert has_element?(
               view,
               "#settings-tally-connector h2",
               "TallyPrime"
             )

      assert has_element?(
               view,
               "#settings-tally-connector #settings-download-tally-connector[download][href='https://github.com/KaguyaHQ/nila-downloads/releases/latest/download/NilaConnector-win-x64-setup.exe']",
               "Download connector"
             )

      assert has_element?(view, "#settings-download-tally-connector[data-variant='soft']")

      assert has_element?(view, "#settings-document-intake > h2", "Document intake")
      assert has_element?(view, "#settings-document-intake.hidden")

      assert has_element?(
               view,
               "#settings-add-channel-disclosure:not([open]) > summary h3",
               "Add a channel"
             )

      assert has_element?(
               view,
               "#settings-add-gmail-disclosure[name='settings-add-provider']:not([open]) #settings-add-gmail-form"
             )

      assert has_element?(
               view,
               "#settings-add-microsoft-disclosure[name='settings-add-provider']:not([open]) #settings-add-microsoft-form"
             )

      assert has_element?(view, "#settings-add-microsoft-tenant")
      assert has_element?(view, "#settings-add-microsoft-mailbox")
      assert has_element?(view, "#settings-add-microsoft[data-variant='soft']")
      assert has_element?(view, "#settings-connect-whatsapp", "Connect WhatsApp")

      assert has_element?(
               view,
               ~s|img[data-provider-logo="gmail"][src="/images/providers/google-gmail.svg"]|
             )

      assert has_element?(
               view,
               ~s|img[data-provider-logo="microsoft"][src="/images/providers/microsoft.svg"]|
             )

      assert has_element?(
               view,
               ~s|img[data-provider-logo="whatsapp"][src="/images/providers/whatsapp.svg"]|
             )

      assert has_element?(
               view,
               ~s|form#settings-add-microsoft-form[action="/integrations/microsoft/connect"]|
             )
    end

    test "redirects /settings to workspace settings", %{conn: conn} do
      conn = get(conn, ~p"/settings")

      assert redirected_to(conn) == ~p"/settings/workspace"
    end

    test "keeps product and settings navigation in one LiveView session" do
      sessions =
        NilaWeb.Router.__routes__()
        |> Enum.filter(
          &(&1.path in ["/sales-bills", "/settings/profile", "/settings/connectors"])
        )
        |> Enum.map(fn route ->
          {_view, _action, _opts, session} = route.metadata.phoenix_live_view
          {route.path, session.name}
        end)
        |> Map.new()

      assert sessions == %{
               "/sales-bills" => :require_verified,
               "/settings/profile" => :require_verified,
               "/settings/connectors" => :require_verified
             }
    end

    test "renders the firm settings form in the settings shell", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/workspace")

      assert has_element?(view, "#app-shell")
      assert has_element?(view, "#settings-cockpit")
      assert has_element?(view, "#settings-nav")
      assert has_element?(view, "#settings-workspace")
      assert has_element?(view, "#settings-firm-form")
      assert has_element?(view, ~s|#settings-firm-form input[name="org[name]"]|)
      assert has_element?(view, ~s|#settings-firm-form input[name="org[contact_phone]"]|)

      assert has_element?(
               view,
               "#settings-save-firm[data-variant='primary']:not([disabled])",
               "Save changes"
             )

      refute has_element?(view, ~s|#settings-firm-form input[name="org[legal_name]"]|)
      refute has_element?(view, ~s|#settings-firm-form input[name="org[gstin]"]|)
      refute has_element?(view, ~s|#settings-firm-form input[name="org[address_line1]"]|)
      assert has_element?(view, ~s|a[aria-current="page"][href="/settings/workspace"]|)
    end

    test "updates the shared firm details", %{conn: conn, org: org} do
      {:ok, view, _html} = live(conn, ~p"/settings/workspace")

      view
      |> form("#settings-firm-form",
        org: %{
          name: "Balaji & Associates",
          contact_phone: "9962550448"
        }
      )
      |> render_submit()

      firm = Orgs.get_org!(org.id)
      assert firm.name == "Balaji & Associates"
      assert firm.contact_phone == "9962550448"
      assert firm.legal_name == org.legal_name
      assert firm.gstin == org.gstin
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

    test "healthy active WhatsApp is calm and keeps verification subordinate", %{
      conn: conn,
      org: org
    } do
      connection = whatsapp_connection(org)
      {:ok, view, _html} = live(conn, ~p"/settings/connectors")

      assert has_element?(view, "#settings-connected-accounts h3", "Configured channels")

      assert has_element?(
               view,
               "#settings-connection-state-#{connection.id}",
               "Ready to receive documents."
             )

      refute has_element?(view, "#settings-connection-#{connection.id} [data-primary-action]")

      assert has_element?(
               view,
               "#settings-edit-connection-#{connection.id}:not([open]) #settings-verify-connection-#{connection.id}[data-variant='ghost']"
             )

      assert has_element?(
               view,
               "#settings-connection-#{connection.id} p.text-ui",
               "Last received: Never"
             )

      assert has_element?(
               view,
               "#settings-add-channel-disclosure:not([open]) > summary h3",
               "Add another channel"
             )

      assert has_element?(
               view,
               "#settings-add-channel-disclosure #settings-connect-whatsapp",
               "Add another WhatsApp number"
             )
    end

    test "degraded active WhatsApp explains the failure and offers only retry verification", %{
      conn: conn,
      org: org
    } do
      connection = whatsapp_connection(org)

      assert {:ok, _degraded} =
               Integrations.mark_degraded(connection, :whatsapp_readiness_check_failed)

      {:ok, view, _html} = live(conn, ~p"/settings/connectors")

      assert has_element?(
               view,
               "#settings-connection-state-#{connection.id}",
               "Nila could not verify this WhatsApp connection. Intake may be interrupted."
             )

      assert has_element?(
               view,
               "#settings-verify-connection-#{connection.id}[data-primary-action]",
               "Retry verification"
             )

      refute has_element?(view, "#settings-reconnect-connection-#{connection.id}")

      refute has_element?(
               view,
               "#settings-connection-#{connection.id} p",
               ":whatsapp_readiness_check_failed"
             )

      view |> element("#settings-verify-connection-#{connection.id}") |> render_click()

      verified = Repo.get!(Integrations.Connection, connection.id)
      assert verified.last_status == "connected"
      assert verified.last_error == nil

      assert has_element?(
               view,
               "#settings-connection-state-#{connection.id}",
               "Ready to receive documents."
             )

      refute has_element?(view, "#settings-connection-#{connection.id} [data-primary-action]")
    end

    test "disconnect after an error clears stale state and makes Meta reconnect primary", %{
      conn: conn,
      org: org
    } do
      connection = whatsapp_connection(org)
      assert {:ok, degraded} = Integrations.mark_degraded(connection, "old provider failure")

      {:ok, view, _html} = live(conn, ~p"/settings/connectors")

      view |> element("#settings-disconnect-connection-#{degraded.id}") |> render_click()

      disconnected = Repo.get!(Integrations.Connection, degraded.id)
      assert disconnected.status == "disconnected"
      assert disconnected.last_status == "revoked"
      assert disconnected.last_error == nil
      assert disconnected.credentials == %{}

      assert has_element?(
               view,
               "#settings-connection-state-#{connection.id}",
               "Intake is paused. Reconnect with Meta to resume receiving documents."
             )

      assert has_element?(
               view,
               "#settings-reconnect-connection-#{connection.id}[data-whatsapp-launch][data-primary-action]",
               "Reconnect with Meta"
             )

      refute has_element?(view, "#settings-verify-connection-#{connection.id}")
      refute has_element?(view, "#settings-disconnect-connection-#{connection.id}")

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
      assert Repo.get!(Integrations.Connection, connection.id).status == "disconnected"
    end

    test "removes a disconnected WhatsApp connection", %{conn: conn, org: org} do
      connection = whatsapp_connection(org)
      assert {:ok, _disconnected} = Integrations.disconnect(connection)

      {:ok, view, _html} = live(conn, ~p"/settings/connectors")

      assert has_element?(
               view,
               "#settings-remove-connection-#{connection.id}[data-variant='error']",
               "Remove connection"
             )

      view |> element("#settings-remove-connection-#{connection.id}") |> render_click()

      assert {:error, :not_found} = Integrations.get_connection(connection.id)
      refute has_element?(view, "#settings-connection-#{connection.id}")
      refute has_element?(view, "#settings-connected-accounts")
      assert has_element?(view, "#settings-add-channel-disclosure:not([open])")
    end

    test "legacy disconnected WhatsApp hides a stored raw readiness error", %{
      conn: conn,
      org: org
    } do
      assert {:ok, connection} =
               Integrations.upsert_connection(%{
                 org_id: org.id,
                 provider: "whatsapp",
                 status: "disconnected",
                 last_status: "error",
                 last_error: ":whatsapp_readiness_check_failed",
                 external_account_id: "919876543210",
                 credentials: %{},
                 settings: %{"display_phone_number" => "+91 98765 43210"}
               })

      {:ok, view, _html} = live(conn, ~p"/settings/connectors")

      assert has_element?(
               view,
               "#settings-connection-state-#{connection.id}",
               "Intake is paused. Reconnect with Meta to resume receiving documents."
             )

      assert has_element?(
               view,
               "#settings-reconnect-connection-#{connection.id}[data-primary-action]",
               "Reconnect with Meta"
             )

      refute has_element?(
               view,
               "#settings-connection-#{connection.id} p",
               ":whatsapp_readiness_check_failed"
             )
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

      assert has_element?(
               view,
               "#settings-connection-#{connection.id} h3.wrap-break-word:not(.truncate)",
               "Caltech invoices"
             )

      assert has_element?(
               view,
               "#settings-connection-#{connection.id} p.wrap-break-word:not(.truncate)",
               "caltech@example.com"
             )

      assert has_element?(view, "#settings-connected-accounts + #settings-add-channel")

      assert has_element?(
               view,
               "#settings-add-channel-disclosure:not([open]) #settings-add-gmail-form"
             )

      assert has_element?(
               view,
               "#settings-connection-#{connection.id} p.text-ui",
               "Last sync: Never"
             )

      assert has_element?(
               view,
               "#settings-edit-connection-#{connection.id}:not([open]) #settings-save-connection-#{connection.id}[data-variant='ghost']"
             )

      assert has_element?(
               view,
               "#settings-edit-connection-#{connection.id}:not([open]) #settings-disconnect-connection-#{connection.id}[data-variant='ghost'][data-confirm]"
             )

      view
      |> form("#settings-connection-form-#{connection.id}",
        connection: %{label: "GRN tracking"}
      )
      |> render_submit()

      assert Repo.get!(Integrations.Connection, connection.id).label == "GRN tracking"

      view |> element("#settings-disconnect-connection-#{connection.id}") |> render_click()
      assert Repo.get!(Integrations.Connection, connection.id).status == "disconnected"

      assert has_element?(
               view,
               "#settings-reconnect-connection-#{connection.id}[data-primary-action]"
             )

      view |> element("#settings-reconnect-connection-#{connection.id}") |> render_click()
      assert Repo.get!(Integrations.Connection, connection.id).status == "active"
    end
  end

  defp whatsapp_connection(org) do
    {:ok, connection} =
      Integrations.complete_whatsapp_signup(org.id, "valid-code", %{
        "business_id" => "111111111",
        "waba_id" => "222222222",
        "phone_number_id" => "333333333"
      })

    connection
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
