defmodule NilaWeb.WhatsAppWebhookTest do
  use NilaWeb.ConnCase, async: true

  alias Nila.Integrations
  alias Nila.Orgs
  alias Nila.Repo

  @secret "dev-whatsapp-app-secret"

  test "verifies webhook challenge", %{conn: conn} do
    conn =
      get(conn, ~p"/webhooks/whatsapp", %{
        "hub.mode" => "subscribe",
        "hub.verify_token" => "dev-whatsapp-verify-token",
        "hub.challenge" => "challenge-value"
      })

    assert response(conn, 200) == "challenge-value"
  end

  test "rejects invalid webhook signatures", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", "sha256=bad")
      |> post(~p"/webhooks/whatsapp", Jason.encode!(payload()))

    assert response(conn, 401) == "invalid signature"
  end

  test "enqueues WhatsApp ingest for a known phone number", %{conn: conn} do
    org =
      Orgs.create_org!(%{
        name: "WhatsApp Test Co",
        legal_name: "WhatsApp Test Company",
        gstin: "29ABCDE1234F1ZW"
      })

    {:ok, connection} =
      Integrations.upsert_connection(%{
        org_id: org.id,
        provider: "whatsapp",
        status: "active",
        external_account_id: "12345",
        credentials: %{"access_token" => "whatsapp-token"}
      })

    body = Jason.encode!(payload())

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", signature(body))
      |> post(~p"/webhooks/whatsapp", body)

    assert json_response(conn, 200) == %{"ok" => true}

    assert [%Oban.Job{worker: "Nila.Integrations.WhatsAppIngestWorker"} = job] =
             Repo.all(Oban.Job)

    assert job.args["connection_id"] == connection.id

    assert get_in(job.args, [
             "payload",
             "entry",
             Access.at(0),
             "changes",
             Access.at(0),
             "value",
             "metadata",
             "phone_number_id"
           ]) ==
             "12345"
  end

  defp signature(body) do
    "sha256=" <>
      (:crypto.mac(:hmac, :sha256, @secret, body)
       |> Base.encode16(case: :lower))
  end

  defp payload do
    %{
      "entry" => [
        %{
          "changes" => [
            %{
              "value" => %{
                "metadata" => %{"phone_number_id" => "12345"},
                "messages" => [
                  %{
                    "id" => "wamid.1",
                    "image" => %{"id" => "media-1", "mime_type" => "image/jpeg"}
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
