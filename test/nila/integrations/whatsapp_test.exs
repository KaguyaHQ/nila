defmodule Nila.Integrations.WhatsAppTest do
  use ExUnit.Case, async: true

  alias Nila.Integrations.{Connection, WhatsApp}

  test "normalizes media, text evidence, and template quick replies" do
    reply_payload = "reply-payload"

    payload = %{
      "entry" => [
        %{
          "changes" => [
            %{
              "value" => %{
                "messages" => [
                  %{
                    "id" => "wamid.media",
                    "from" => "919876543210",
                    "document" => %{
                      "id" => "media-1",
                      "filename" => "sales.pdf",
                      "mime_type" => "application/pdf"
                    }
                  },
                  %{
                    "id" => "wamid.reply",
                    "from" => "919876543210",
                    "button" => %{
                      "payload" => reply_payload,
                      "text" => "Yes, everything sent"
                    }
                  },
                  %{
                    "id" => "wamid.text",
                    "from" => "919876543210",
                    "text" => %{"body" => "Two invoices are cancelled"}
                  }
                ]
              }
            }
          ]
        }
      ]
    }

    assert {:ok, [media, reply, text]} = WhatsApp.normalize(payload, [])
    assert media.type == :media
    assert media.filename == "sales.pdf"
    assert reply.type == :button_reply
    assert reply.payload == reply_payload
    assert reply.source_ref == "whatsapp:wamid.reply"
    assert text.type == :text
    assert text.body == "Two invoices are cancelled"
    assert text.source_ref == "whatsapp:wamid.text"
  end

  test "normalizes interactive button replies" do
    payload = %{
      "entry" => [
        %{
          "changes" => [
            %{
              "value" => %{
                "messages" => [
                  %{
                    "id" => "wamid.reply",
                    "from" => "919876543210",
                    "interactive" => %{
                      "type" => "button_reply",
                      "button_reply" => %{"id" => "payload", "title" => "Everything sent"}
                    }
                  }
                ]
              }
            }
          ]
        }
      ]
    }

    assert {:ok, [reply]} = WhatsApp.normalize(payload, [])

    assert reply == %{
             type: :button_reply,
             payload: "payload",
             text: "Everything sent",
             sender: "919876543210",
             source_ref: "whatsapp:wamid.reply",
             provider_context_ref: nil
           }
  end

  test "fetches media through the configured Req adapter" do
    Req.Test.expect(WhatsApp, fn conn ->
      assert conn.request_path == "/v26.0/media-1"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer token"]
      Req.Test.json(conn, %{"url" => "https://lookaside.example/media-1"})
    end)

    Req.Test.expect(WhatsApp, fn conn ->
      assert conn.request_path == "/media-1"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer token"]
      Plug.Conn.send_resp(conn, 200, "%PDF-media")
    end)

    assert {:ok, "%PDF-media"} = WhatsApp.fetch_media("media-1", "token")
  end

  test "halts media downloads above the configured size limit" do
    Req.Test.expect(WhatsApp, fn conn ->
      Req.Test.json(conn, %{"url" => "https://lookaside.example/media-large"})
    end)

    Req.Test.expect(WhatsApp, fn conn ->
      Plug.Conn.send_resp(conn, 200, String.duplicate("x", 17))
    end)

    assert {:error, {:whatsapp_media_too_large, 17}} =
             WhatsApp.fetch_media("media-large", "token")
  end

  test "returns an error when outbound credentials are missing" do
    connection = %Connection{external_account_id: "phone-number-123", credentials: %{}}

    assert {:error, :missing_access_token} =
             WhatsApp.send_message(connection, "919876543210", "Send the bills", "template")
  end
end
