defmodule Nila.IntegrationsTest do
  use Nila.DataCase, async: true

  alias Nila.Integrations
  alias Nila.Orgs
  alias Nila.Repo

  setup do
    org =
      Orgs.create_org!(%{
        name: "Connector Test Co",
        legal_name: "Connector Test Company",
        gstin: "29ABCDE1234F1ZW"
      })

    %{org: org}
  end

  test "upserts connection credentials encrypted at rest", %{org: org} do
    assert {:ok, connection} =
             Integrations.upsert_connection(%{
               org_id: org.id,
               label: "Caltech invoices",
               provider: "gmail",
               status: "active",
               external_account_id: "inbox@example.com",
               credentials: %{
                 "access_token" => "access-secret",
                 "refresh_token" => "refresh-secret"
               },
               settings: %{"query" => "has:attachment"}
             })

    assert connection.credentials["refresh_token"] == "refresh-secret"
    assert connection.label == "Caltech invoices"

    %{rows: [[stored_credentials]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "select credentials from integration_connections where id = $1",
        [connection.id]
      )

    refute stored_credentials =~ "refresh-secret"

    assert {:ok, updated} =
             Integrations.upsert_connection(%{
               org_id: org.id,
               label: "Renamed inbox",
               provider: "gmail",
               status: "active",
               external_account_id: "inbox@example.com",
               credentials: %{"access_token" => "new-secret"},
               settings: %{"query" => "filename:pdf"}
             })

    assert updated.id == connection.id
    assert updated.credentials["access_token"] == "new-secret"
    assert updated.label == "Renamed inbox"
    assert Repo.aggregate(Nila.Integrations.Connection, :count) == 1
  end

  test "provisions and rotates an encrypted WhatsApp connection", %{org: org} do
    attrs = %{
      org_id: org.id,
      phone_number_id: " 123456789 ",
      access_token: " first-secret ",
      label: " Firm WhatsApp "
    }

    assert {:ok, connection} = Integrations.provision_whatsapp(attrs)
    assert connection.provider == "whatsapp"
    assert connection.external_account_id == "123456789"
    assert connection.credentials == %{"access_token" => "first-secret"}
    assert connection.label == "Firm WhatsApp"

    %{rows: [[stored_credentials]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "select credentials from integration_connections where id = $1",
        [connection.id]
      )

    refute stored_credentials =~ "first-secret"

    assert {:ok, rotated} =
             Integrations.provision_whatsapp(%{
               org_id: org.id,
               phone_number_id: "123456789",
               access_token: "second-secret"
             })

    assert rotated.id == connection.id
    assert rotated.credentials == %{"access_token" => "second-secret"}
    assert Repo.aggregate(Nila.Integrations.Connection, :count) == 1
  end

  test "Embedded Signup stores verified WhatsApp metadata and supports clean reauthorization", %{
    org: org
  } do
    session = %{
      "business_id" => "111111111",
      "waba_id" => "222222222",
      "phone_number_id" => "333333333"
    }

    assert {:ok, connection} =
             Integrations.complete_whatsapp_signup(org.id, "valid-code", session)

    assert connection.credentials == %{
             "access_token" => "embedded-signup-token",
             "expires_at" => "2027-01-01T00:00:00Z",
             "token_type" => "bearer",
             "two_step_pin" => "581063"
           }

    assert connection.settings["business_id"] == "111111111"
    assert connection.settings["waba_id"] == "222222222"
    assert connection.settings["webhook_subscribed"]
    assert connection.settings["registered"]

    %{rows: [[stored_credentials]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "select credentials from integration_connections where id = $1",
        [connection.id]
      )

    refute stored_credentials =~ "embedded-signup-token"
    refute stored_credentials =~ "581063"

    assert {:ok, disconnected} = Integrations.disconnect(connection)
    assert disconnected.status == "disconnected"
    assert disconnected.last_status == "revoked"
    assert disconnected.credentials == %{}
    assert {:error, :reauthorization_required} = Integrations.reconnect(disconnected)

    assert {:ok, reconnected} =
             Integrations.complete_whatsapp_signup(org.id, "valid-code", session)

    assert reconnected.id == connection.id
    assert reconnected.status == "active"
    assert reconnected.credentials["access_token"] == "embedded-signup-token"

    assert {:ok, verified} = Integrations.verify_whatsapp_connection(reconnected)
    assert verified.settings["readiness_checked_at"] == "2026-08-03T00:00:00Z"
  end

  test "intentional WhatsApp disconnect clears obsolete error state", %{org: org} do
    assert {:ok, connection} =
             Integrations.provision_whatsapp(%{
               org_id: org.id,
               phone_number_id: "919876543210",
               access_token: "business-token"
             })

    assert {:ok, degraded} =
             Integrations.mark_degraded(connection, :whatsapp_readiness_check_failed)

    assert degraded.last_status == "error"
    assert degraded.last_error == ":whatsapp_readiness_check_failed"

    assert {:ok, disconnected} = Integrations.disconnect(degraded)
    assert disconnected.status == "disconnected"
    assert disconnected.last_status == "revoked"
    assert disconnected.last_error == nil
    assert disconnected.disconnected_at
    assert disconnected.credentials == %{}
  end

  test "a failed reconnect records the reason and leaves the connection retryable", %{org: org} do
    session = %{
      "business_id" => "111111111",
      "waba_id" => "222222222",
      "phone_number_id" => "333333333"
    }

    assert {:ok, connection} =
             Integrations.complete_whatsapp_signup(org.id, "valid-code", session)

    assert {:ok, _disconnected} = Integrations.disconnect(connection)

    assert {:error, :invalid_authorization_code} =
             Integrations.complete_whatsapp_signup(org.id, "stale-code", session)

    failed = Integrations.get_connection!(connection.id)
    assert failed.status == "disconnected"
    assert failed.last_status == "error"
    assert failed.last_error == ":invalid_authorization_code"

    assert {:ok, recovered} =
             Integrations.complete_whatsapp_signup(org.id, "valid-code", session)

    assert recovered.status == "active"
    assert recovered.last_error == nil
  end

  test "a provider error body never reaches the rendered connection error", %{org: org} do
    session = %{
      "business_id" => "111111111",
      "waba_id" => "222222222",
      "phone_number_id" => "333333333"
    }

    assert {:ok, connection} =
             Integrations.complete_whatsapp_signup(org.id, "valid-code", session)

    assert {:ok, degraded} =
             Integrations.mark_degraded(
               connection,
               {:whatsapp_token_exchange_failed, 400,
                %{"error" => %{"message" => "expired code", "fbtrace_id" => "AbC123"}}}
             )

    assert degraded.last_error == "whatsapp_token_exchange_failed (HTTP 400)"
    refute degraded.last_error =~ "fbtrace_id"
  end

  test "a failed signup leaves an active connection untouched", %{org: org} do
    session = %{
      "business_id" => "111111111",
      "waba_id" => "222222222",
      "phone_number_id" => "333333333"
    }

    assert {:ok, connection} =
             Integrations.complete_whatsapp_signup(org.id, "valid-code", session)

    assert {:error, :invalid_authorization_code} =
             Integrations.complete_whatsapp_signup(org.id, "stale-code", session)

    unchanged = Integrations.get_connection!(connection.id)
    assert unchanged.status == "active"
    assert unchanged.last_status == "connected"
    assert unchanged.last_error == nil
  end

  test "one WhatsApp phone-number ID cannot bind to two organisations", %{org: org} do
    other_org = Nila.AccountsFixtures.org_fixture()

    assert {:ok, _connection} =
             Integrations.provision_whatsapp(%{
               org_id: org.id,
               phone_number_id: "123456789",
               access_token: "first-secret"
             })

    assert {:error, :whatsapp_account_already_connected} =
             Integrations.provision_whatsapp(%{
               org_id: other_org.id,
               phone_number_id: "123456789",
               access_token: "second-secret"
             })

    assert {:error, changeset} =
             Integrations.upsert_connection(%{
               org_id: other_org.id,
               provider: "whatsapp",
               external_account_id: "123456789",
               credentials: %{"access_token" => "second-secret"}
             })

    assert "is already connected to another workspace" in errors_on(changeset).external_account_id
  end

  test "a stale Gmail token is refreshed through the adapter and persisted", %{org: org} do
    assert {:ok, connection} =
             Integrations.upsert_connection(%{
               org_id: org.id,
               provider: "gmail",
               external_account_id: "firm@example.com",
               credentials: %{
                 "access_token" => "stale",
                 "refresh_token" => "refresh-secret",
                 "expires_at" => DateTime.utc_now() |> DateTime.add(-60) |> DateTime.to_iso8601()
               }
             })

    Req.Test.expect(Nila.Integrations.Gmail, fn conn ->
      {:ok, bytes, conn} = Plug.Conn.read_body(conn)
      form = URI.decode_query(bytes)

      assert form["grant_type"] == "refresh_token"
      assert form["refresh_token"] == "refresh-secret"

      Req.Test.json(conn, %{"access_token" => "fresh", "expires_in" => 3600})
    end)

    assert {:ok, refreshed} = Integrations.ensure_token(connection)
    assert refreshed.credentials["access_token"] == "fresh"
    assert refreshed.credentials["refresh_token"] == "refresh-secret"
    assert Integrations.token_fresh?(refreshed.credentials)

    assert {:ok, reused} = Integrations.ensure_token(refreshed)
    assert reused.credentials["access_token"] == "fresh"
  end

  test "email delivery resolves any connected mail provider, not just Gmail", %{org: org} do
    assert is_nil(Integrations.first_active_email_connection(org.id))

    assert {:ok, _whatsapp} =
             Integrations.upsert_connection(%{
               org_id: org.id,
               provider: "whatsapp",
               external_account_id: "phone-number-123",
               credentials: %{"access_token" => "token"}
             })

    assert is_nil(Integrations.first_active_email_connection(org.id))

    assert {:ok, microsoft} =
             Integrations.upsert_connection(%{
               org_id: org.id,
               provider: "microsoft",
               external_account_id: "mail@bvccas.com",
               credentials: %{"access_token" => "token"}
             })

    assert Integrations.first_active_email_connection(org.id).id == microsoft.id

    assert {:ok, _disconnected} = Integrations.disconnect(microsoft)
    assert is_nil(Integrations.first_active_email_connection(org.id))
  end

  test "operator edits cannot reach the grant or the send-as mailbox", %{org: org} do
    assert {:ok, connection} =
             Integrations.upsert_connection(%{
               org_id: org.id,
               provider: "microsoft",
               external_account_id: "mail@bvccas.com",
               credentials: %{"access_token" => "token"},
               settings: %{"tenant_id" => "real-tenant"}
             })

    assert {:ok, updated} =
             Integrations.update_connection(connection, %{
               label: "Firm mailbox",
               settings: %{"tenant_id" => "attacker-tenant"},
               credentials: %{"access_token" => "attacker-token"},
               external_account_id: "partner@bvccas.com"
             })

    assert updated.label == "Firm mailbox"
    assert updated.settings == %{"tenant_id" => "real-tenant"}
    assert updated.credentials == %{"access_token" => "token"}
    assert updated.external_account_id == "mail@bvccas.com"
  end

  test "a Microsoft tenant binds to one workspace only", %{org: org} do
    other_org = Nila.AccountsFixtures.org_fixture()
    tenant = "11111111-2222-3333-4444-555555555555"

    assert {:ok, _connection} =
             Integrations.upsert_connection(%{
               org_id: org.id,
               provider: "microsoft",
               external_account_id: "mail@bvccas.com",
               tenant_id: tenant,
               credentials: %{}
             })

    assert {:error, changeset} =
             Integrations.upsert_connection(%{
               org_id: other_org.id,
               provider: "microsoft",
               external_account_id: "mail@bvccas.com",
               tenant_id: tenant,
               credentials: %{}
             })

    assert "is already connected to another workspace" in errors_on(changeset).tenant_id
  end

  test "a provider with no adapter errors instead of raising" do
    assert {:error, {:unsupported_provider, "zoho"}} = Integrations.fetch_adapter("zoho")

    assert {:error, {:unsupported_provider, "zoho"}} =
             Integrations.ensure_token(%Integrations.Connection{provider: "zoho"})
  end

  test "connection status helpers support settings health", %{org: org} do
    assert {:ok, connection} =
             Integrations.upsert_connection(%{
               org_id: org.id,
               label: "GRN tracking",
               provider: "gmail",
               status: "active",
               external_account_id: "grn@example.com",
               credentials: %{"access_token" => "token"}
             })

    assert %{ok: 1, degraded: []} = Integrations.health_summary(org.id)

    assert {:ok, errored} = Integrations.mark_error(connection, "OAuth expired", "expired")

    assert errored.status == "error"
    assert errored.last_status == "expired"

    assert [%{label: "GRN tracking", last_error: "OAuth expired"}] =
             Integrations.health_summary(org.id).degraded

    assert {:ok, disconnected} = Integrations.disconnect(errored)
    assert disconnected.disconnected_at
    assert disconnected.last_status == "revoked"
    assert disconnected.last_error == nil

    assert {:ok, reconnected} = Integrations.reconnect(disconnected)
    assert reconnected.status == "active"
    assert reconnected.disconnected_at == nil
    assert reconnected.last_status == "connected"
  end
end
