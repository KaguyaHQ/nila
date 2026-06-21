defmodule Nila.IntegrationsTest do
  use Nila.DataCase

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

    entity = Orgs.get_or_create_default_entity!(org.id)

    %{org: org, entity: entity}
  end

  test "upserts connection credentials encrypted at rest", %{org: org, entity: entity} do
    assert {:ok, connection} =
             Integrations.upsert_connection(%{
               org_id: org.id,
               entity_id: entity.id,
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
    assert connection.entity_id == entity.id
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
               entity_id: entity.id,
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

  test "connection status helpers support settings health", %{org: org, entity: entity} do
    assert {:ok, connection} =
             Integrations.upsert_connection(%{
               org_id: org.id,
               entity_id: entity.id,
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
