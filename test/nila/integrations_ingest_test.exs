defmodule Nila.IntegrationsIngestTest do
  # Sync on purpose: these tests swap the :whatsapp_adapter application env,
  # which is global. Running async would let one test's stub leak into
  # another's.
  use Nila.DataCase, async: false
  use Oban.Testing, repo: Nila.Repo

  import Nila.AccountsFixtures

  alias Nila.Clients
  alias Nila.Gst.Intake.Arrivals
  alias Nila.Integrations
  alias Nila.Integrations.{WhatsAppEventWorker, WhatsAppIngestWorker}

  setup do
    whatsapp_adapter = Application.get_env(:nila, :whatsapp_adapter)

    on_exit(fn ->
      Application.put_env(:nila, :whatsapp_adapter, whatsapp_adapter)
    end)

    %{org: org_fixture()}
  end

  test "WhatsApp media from a known number is attributed and an unknown number is held", %{
    org: org
  } do
    Application.put_env(:nila, :whatsapp_adapter, Nila.Integrations.WhatsAppStub)
    connection = connection!(org, "whatsapp", "phone-number-123")
    {:ok, _connection} = Integrations.mark_degraded(connection, :previous_failure)

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Ravi Traders",
        type: "company",
        phone: "9876543210"
      })

    assert :ok =
             dispatch_whatsapp(
               connection,
               whatsapp_payload("919876543210", "known.pdf")
             )

    assert :ok =
             dispatch_whatsapp(
               connection,
               whatsapp_payload("919876543210", "known.pdf")
             )

    assert :ok =
             dispatch_whatsapp(
               connection,
               whatsapp_payload("919999999999", "unknown.pdf")
             )

    arrivals = Arrivals.pending_for_org(org.id)
    assert length(arrivals) == 2
    assert Enum.find(arrivals, &(&1.filename == "known.pdf")).client_id == client.id

    unknown = Enum.find(arrivals, &(&1.filename == "unknown.pdf"))
    assert is_nil(unknown.client_id)
    assert unknown.sender == "919999999999"
    assert unknown.source == "whatsapp"
    refreshed_connection = Integrations.get_connection!(connection.id)
    assert refreshed_connection.last_status == "connected"
    assert refreshed_connection.last_synced_at
  end

  test "queued WhatsApp jobs stop cleanly after a connection is removed", %{org: org} do
    connection = connection!(org, "whatsapp", "phone-number-123")
    {:ok, disconnected} = Integrations.disconnect(connection)
    {:ok, _removed} = Integrations.remove_whatsapp_connection(disconnected)

    assert :ok =
             perform_job(WhatsAppIngestWorker, %{
               "connection_id" => connection.id,
               "payload" => %{}
             })

    assert :ok =
             perform_job(WhatsAppEventWorker, %{
               "connection_id" => connection.id,
               "event" => %{}
             })
  end

  @tag :capture_log
  test "one failed WhatsApp event does not block siblings", %{org: org} do
    Application.put_env(:nila, :whatsapp_adapter, Nila.Integrations.WhatsAppStub)
    connection = connection!(org, "whatsapp", "phone-number-123")
    Process.put(:whatsapp_media_result, {:error, :media_unavailable})

    payload =
      whatsapp_messages([
        %{
          "id" => "wamid.failed-media",
          "from" => "919876543210",
          "document" => %{
            "id" => "media-failed",
            "filename" => "failed.pdf",
            "mime_type" => "application/pdf"
          }
        },
        %{
          "id" => "wamid.sibling-text",
          "from" => "919876543210",
          "text" => %{"body" => "The media upload failed"}
        }
      ])

    assert :ok =
             perform_job(WhatsAppIngestWorker, %{
               "connection_id" => connection.id,
               "payload" => payload
             })

    assert %{failure: 1, success: 1} = Oban.drain_queue(queue: :whatsapp)

    assert Nila.Repo.get_by(Nila.Gst.Intake.Message,
             org_id: org.id,
             source_ref: "whatsapp:wamid.sibling-text"
           )

    assert Integrations.get_connection!(connection.id).last_status == "error"
  end

  defp connection!(org, provider, external_account_id) do
    {:ok, connection} =
      Integrations.upsert_connection(%{
        org_id: org.id,
        provider: provider,
        external_account_id: external_account_id,
        credentials: %{
          "access_token" => "token",
          "refresh_token" => "refresh",
          "expires_at" => DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()
        }
      })

    connection
  end

  defp whatsapp_payload(sender, filename) do
    whatsapp_message(%{
      "id" => "wamid.#{filename}",
      "from" => sender,
      "document" => %{
        "id" => "media-#{filename}",
        "filename" => filename,
        "mime_type" => "application/pdf"
      }
    })
  end

  defp dispatch_whatsapp(connection, payload) do
    with :ok <-
           perform_job(WhatsAppIngestWorker, %{
             "connection_id" => connection.id,
             "payload" => payload
           }),
         %{failure: 0} <- Oban.drain_queue(queue: :whatsapp) do
      :ok
    end
  end

  defp whatsapp_message(message), do: whatsapp_messages([message])

  defp whatsapp_messages(messages) do
    %{
      "entry" => [
        %{
          "changes" => [
            %{
              "value" => %{
                "messages" => messages
              }
            }
          ]
        }
      ]
    }
  end
end
