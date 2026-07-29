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

    assert {:ok, reconnected} = Integrations.reconnect(disconnected)
    assert reconnected.status == "active"
    assert reconnected.disconnected_at == nil
    assert reconnected.last_status == "connected"
  end
end
