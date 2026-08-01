defmodule Nila.IntegrationsIngestTest do
  # Sync on purpose: these tests swap the :gmail_adapter / :whatsapp_adapter
  # application env, which is global. Running async would let one test's stub
  # leak into another's.
  use Nila.DataCase, async: false
  use Oban.Testing, repo: Nila.Repo

  import Nila.AccountsFixtures

  alias Nila.Clients
  alias Nila.Gst.Chase
  alias Nila.Gst.Intake.{Arrivals, Confirmations, Messages}
  alias Nila.Integrations
  alias Nila.Integrations.{GmailSyncWorker, WhatsAppIngestWorker, WhatsAppReply}

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
    Application.put_env(:nila, :whatsapp_adapter, Nila.Integrations.WhatsAppStub)
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

  test "WhatsApp button replies record period completeness and text remains evidence", %{
    org: org
  } do
    Application.put_env(:nila, :whatsapp_adapter, Nila.Integrations.WhatsAppStub)
    connection = connection!(org, "whatsapp", "phone-number-123")

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Ravi Traders",
        type: "company",
        phone: "9876543210"
      })

    ask_ref = Ecto.UUID.generate()

    {:ok, _ask} =
      Chase.record_ask(%{org_id: org.id, client_id: client.id}, %{
        kind: "sales_completeness",
        period: "2026-06",
        body: "Have you sent everything for June 2026?",
        channel: "whatsapp",
        ask_ref: ask_ref,
        provider_ref: "wamid.question"
      })

    {:ok, reply_payload} = WhatsAppReply.sign(ask_ref, "client_yes")

    assert :ok =
             perform_job(WhatsAppIngestWorker, %{
               "connection_id" => connection.id,
               "payload" => whatsapp_button_payload("919876543210", reply_payload)
             })

    assert Confirmations.status(org.id, client.id, "2026-06") == :complete

    assert :ok =
             perform_job(WhatsAppIngestWorker, %{
               "connection_id" => connection.id,
               "payload" =>
                 whatsapp_text_payload(
                   "919876543210",
                   "Two invoices are cancelled",
                   "wamid.question"
                 )
             })

    assert [message] = Messages.list(org.id, client.id, "2026-06")
    assert message.body == "Two invoices are cancelled"
  end

  test "Gmail attachments from a client are attributed and stranger mail is held", %{org: org} do
    Application.put_env(:nila, :gmail_adapter, Nila.Integrations.GmailStub)
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
      },
      %{
        filename: "missing-sender.pdf",
        bytes: "%PDF-1.4 missing sender",
        content_type: "application/pdf",
        sender: nil
      }
    ])

    assert :ok = perform_job(GmailSyncWorker, %{"connection_id" => connection.id})

    arrivals = Arrivals.pending_for_org(org.id)
    assert length(arrivals) == 2

    known = Enum.find(arrivals, &(&1.filename == "known.pdf"))
    assert known.client_id == client.id
    assert known.sender == "ravi@example.com"
    assert known.source == "email"

    stranger = Enum.find(arrivals, &(&1.filename == "stranger.pdf"))
    assert is_nil(stranger.client_id)
    assert stranger.sender == "stranger@example.com"
    assert stranger.source == "email"
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

  defp whatsapp_button_payload(sender, reply_payload) do
    whatsapp_message(%{
      "id" => "wamid.completeness-reply",
      "from" => sender,
      "button" => %{"payload" => reply_payload, "text" => "Yes, everything sent"}
    })
  end

  defp whatsapp_text_payload(sender, body, context_ref) do
    whatsapp_message(%{
      "id" => "wamid.text-reply",
      "from" => sender,
      "context" => %{"id" => context_ref},
      "text" => %{"body" => body}
    })
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

  defp whatsapp_message(message) do
    %{
      "entry" => [
        %{
          "changes" => [
            %{
              "value" => %{
                "messages" => [
                  message
                ]
              }
            }
          ]
        }
      ]
    }
  end
end
