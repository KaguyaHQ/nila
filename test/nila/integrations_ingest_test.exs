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
    completeness_secret = Application.get_env(:nila, :whatsapp_completeness_secret)

    on_exit(fn ->
      Application.put_env(:nila, :gmail_adapter, gmail_adapter)
      Application.put_env(:nila, :whatsapp_adapter, whatsapp_adapter)
      Application.put_env(:nila, :whatsapp_completeness_secret, completeness_secret)
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
             dispatch_whatsapp(
               connection,
               whatsapp_button_payload("919876543210", reply_payload)
             )

    assert Confirmations.status(org.id, client.id, "2026-06") == :complete

    assert :ok =
             dispatch_whatsapp(
               connection,
               whatsapp_text_payload(
                 "919876543210",
                 "Two invoices are cancelled",
                 "wamid.question"
               )
             )

    assert [message] = Messages.list(org.id, client.id, "2026-06")
    assert message.body == "Two invoices are cancelled"
  end

  test "an operational button-reply failure is retried", %{org: org} do
    Application.put_env(:nila, :whatsapp_adapter, Nila.Integrations.WhatsAppStub)
    connection = connection!(org, "whatsapp", "phone-number-123")
    ask_ref = Ecto.UUID.generate()
    {:ok, reply_payload} = WhatsAppReply.sign(ask_ref, "client_yes")
    Application.delete_env(:nila, :whatsapp_completeness_secret)

    assert :ok =
             perform_job(WhatsAppIngestWorker, %{
               "connection_id" => connection.id,
               "payload" => whatsapp_button_payload("919876543210", reply_payload)
             })

    assert %{failure: 1, success: 0} = Oban.drain_queue(queue: :whatsapp)
    assert Integrations.get_connection!(connection.id).last_status == "error"
  end

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
