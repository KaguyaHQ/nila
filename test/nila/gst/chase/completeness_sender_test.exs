defmodule Nila.Gst.Chase.CompletenessSenderTest do
  use Nila.DataCase, async: false
  use Oban.Testing, repo: Nila.Repo

  import Nila.AccountsFixtures

  alias Nila.Clients
  alias Nila.Gst.Chase
  alias Nila.Gst.Chase.CompletenessSender
  alias Nila.Gst.Intake.{Confirmations, Dumps}
  alias Nila.Integrations
  alias Nila.Integrations.WhatsAppReply

  setup do
    previous = Application.get_env(:nila, :whatsapp_adapter)
    Application.put_env(:nila, :whatsapp_adapter, Nila.Integrations.WhatsAppStub)
    on_exit(fn -> Application.put_env(:nila, :whatsapp_adapter, previous) end)

    org = org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Breeze Tech",
        type: "company",
        phone: "9876543210",
        chase_channel: "whatsapp"
      })

    {:ok, connection} =
      Integrations.upsert_connection(%{
        org_id: org.id,
        provider: "whatsapp",
        external_account_id: "phone-number-123",
        credentials: %{"access_token" => "token"}
      })

    {:ok, dump} =
      Dumps.record(
        %{org_id: org.id, client_id: client.id},
        %{period: "2026-06", kind: "sales", status: "extracted", invoices: []}
      )

    %{org: org, client: client, connection: connection, dump: dump}
  end

  test "sends one period-bound closeout question after the sales batch", context do
    ask_ref = Ecto.UUID.generate()
    {:ok, _connection} = Integrations.mark_degraded(context.connection, :previous_failure)

    assert :ok =
             perform_job(CompletenessSender, %{
               "org_id" => context.org.id,
               "client_id" => context.client.id,
               "period" => "2026-06",
               "ask_ref" => ask_ref
             })

    assert_receive {:whatsapp_completeness_request, recipient, "June 2026",
                    "nila_sales_completeness", yes_payload, no_payload}

    assert recipient == context.client.phone

    assert {:ok, %{ask_ref: ^ask_ref, decision: "client_yes"}} =
             WhatsAppReply.verify(yes_payload)

    assert {:ok, %{ask_ref: ^ask_ref, decision: "client_no"}} =
             WhatsAppReply.verify(no_payload)

    assert {:ok, ask} = Chase.fetch_ask_by_ref(context.org.id, ask_ref)
    assert ask.kind == "sales_completeness"
    assert ask.provider_ref == "wamid.completeness"

    connected = Integrations.get_connection!(context.connection.id)
    assert connected.last_status == "connected"
    assert is_nil(connected.last_error)
  end

  test "does not ask again once the latest intake is confirmed", context do
    assert {:ok, _} =
             Confirmations.record_client(
               %{org_id: context.org.id},
               context.client.id,
               "2026-06",
               %{
                 decision: "client_yes",
                 channel: "whatsapp",
                 source_ref: "whatsapp:wamid.yes",
                 actor_phone: context.client.phone
               }
             )

    assert :ok =
             perform_job(CompletenessSender, %{
               "org_id" => context.org.id,
               "client_id" => context.client.id,
               "period" => "2026-06",
               "ask_ref" => Ecto.UUID.generate()
             })

    refute_receive {:whatsapp_completeness_request, _, _, _, _, _}
  end
end
