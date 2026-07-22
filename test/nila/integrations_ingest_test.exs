defmodule Nila.IntegrationsIngestTest do
  use Nila.DataCase
  use Oban.Testing, repo: Nila.Repo

  import Nila.AccountsFixtures

  alias Nila.Clients
  alias Nila.Gst.Intake.Arrivals
  alias Nila.Integrations
  alias Nila.Integrations.{GmailSyncWorker, WhatsAppIngestWorker}

  setup do
    gmail_adapter = Application.get_env(:nila, :gmail_adapter)
    whatsapp_adapter = Application.get_env(:nila, :whatsapp_adapter)

    on_exit(fn ->
      Application.put_env(:nila, :gmail_adapter, gmail_adapter)
      Application.put_env(:nila, :whatsapp_adapter, whatsapp_adapter)
    end)

    %{org: org_fixture()}
  end

  test "WhatsApp media from a known number is attributed and an unknown number is held", %{
    org: org
  } do
    Application.put_env(:nila, :whatsapp_adapter, Nila.WhatsAppStub)
    connection = connection!(org, "whatsapp", "phone-number-123")

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Ravi Traders",
        type: "company",
        phone: "9876543210"
      })

    assert :ok =
             perform_job(WhatsAppIngestWorker, %{
               "connection_id" => connection.id,
               "payload" => whatsapp_payload("919876543210", "known.pdf")
             })

    assert :ok =
             perform_job(WhatsAppIngestWorker, %{
               "connection_id" => connection.id,
               "payload" => whatsapp_payload("919876543210", "known.pdf")
             })

    assert :ok =
             perform_job(WhatsAppIngestWorker, %{
               "connection_id" => connection.id,
               "payload" => whatsapp_payload("919999999999", "unknown.pdf")
             })

    arrivals = Arrivals.pending_for_org(org.id)
    assert length(arrivals) == 2
    assert Enum.find(arrivals, &(&1.filename == "known.pdf")).client_id == client.id

    unknown = Enum.find(arrivals, &(&1.filename == "unknown.pdf"))
    assert is_nil(unknown.client_id)
    assert unknown.sender == "919999999999"
    assert unknown.source == "whatsapp"
  end

  test "Gmail attachments from a client become arrivals and stranger mail is ignored", %{org: org} do
    Application.put_env(:nila, :gmail_adapter, Nila.GmailStub)
    connection = connection!(org, "gmail", "firm@example.com")

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Ravi Traders",
        type: "company",
        email: "ravi@example.com"
      })

    Process.put(:gmail_attachments, [
      %{
        filename: "known.pdf",
        bytes: "%PDF-1.4 known",
        content_type: "application/pdf",
        sender: "ravi@example.com"
      },
      %{
        filename: "stranger.pdf",
        bytes: "%PDF-1.4 stranger",
        content_type: "application/pdf",
        sender: "stranger@example.com"
      }
    ])

    assert :ok = perform_job(GmailSyncWorker, %{"connection_id" => connection.id})

    assert [arrival] = Arrivals.pending_for_org(org.id)
    assert arrival.client_id == client.id
    assert arrival.filename == "known.pdf"
    assert arrival.sender == "ravi@example.com"
    assert arrival.source == "email"
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
    %{
      "entry" => [
        %{
          "changes" => [
            %{
              "value" => %{
                "messages" => [
                  %{
                    "id" => "wamid.#{filename}",
                    "from" => sender,
                    "document" => %{
                      "id" => "media-#{filename}",
                      "filename" => filename,
                      "mime_type" => "application/pdf"
                    }
                  }
                ]
              }
            }
          ]
        }
      ]
    }
  end
end
