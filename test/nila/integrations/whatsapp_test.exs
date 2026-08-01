defmodule Nila.Integrations.WhatsAppTest do
  use ExUnit.Case, async: true

  alias Nila.Integrations.{Connection, WhatsApp, WhatsAppReply}

  test "normalizes media, text evidence, and template quick replies" do
    ask_ref = Ecto.UUID.generate()
    {:ok, reply_payload} = WhatsAppReply.sign(ask_ref, "client_yes")

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

  test "sends period-specific Yes and No quick replies" do
    yes_payload = "signed-yes"
    no_payload = "signed-no"

    connection = %Connection{
      external_account_id: "phone-number-123",
      credentials: %{"access_token" => "token"}
    }

    Req.Test.expect(WhatsApp, fn conn ->
      assert conn.request_path == "/v20.0/phone-number-123/messages"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)

      assert payload["to"] == "919876543210"
      assert get_in(payload, ["template", "name"]) == "nila_sales_completeness"

      assert get_in(payload, [
               "template",
               "components",
               Access.at(0),
               "parameters",
               Access.at(0),
               "text"
             ]) == "June 2026"

      assert get_in(payload, [
               "template",
               "components",
               Access.at(1),
               "parameters",
               Access.at(0),
               "payload"
             ]) == yes_payload

      assert get_in(payload, [
               "template",
               "components",
               Access.at(2),
               "parameters",
               Access.at(0),
               "payload"
             ]) == no_payload

      Req.Test.json(conn, %{"messages" => [%{"id" => "wamid.request"}]})
    end)

    assert {:ok, %{"messages" => [%{"id" => "wamid.request"}]}} =
             WhatsApp.send_completeness_request(
               connection,
               "919876543210",
               "June 2026",
               "nila_sales_completeness",
               yes_payload,
               no_payload
             )
  end
end
