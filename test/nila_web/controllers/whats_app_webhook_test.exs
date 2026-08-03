defmodule NilaWeb.WhatsAppWebhookTest do
  use NilaWeb.ConnCase, async: false

  defmodule FailingInserter do
    def insert(_changeset), do: {:error, :database_unavailable}
  end

  alias Nila.Integrations
  alias Nila.Orgs
  alias Nila.Repo

  @secret "dev-whatsapp-app-secret"

  setup do
    inserter = Application.get_env(:nila, :whatsapp_job_inserter)
    controller_config = Application.fetch_env!(:nila, NilaWeb.Webhooks.WhatsAppController)

    on_exit(fn ->
      Application.put_env(:nila, NilaWeb.Webhooks.WhatsAppController, controller_config)

      if inserter do
        Application.put_env(:nila, :whatsapp_job_inserter, inserter)
      else
        Application.delete_env(:nila, :whatsapp_job_inserter)
      end
    end)

    :ok
  end

  test "verifies webhook challenge", %{conn: conn} do
    conn =
      get(conn, ~p"/webhooks/whatsapp", %{
        "hub.mode" => "subscribe",
        "hub.verify_token" => "dev-whatsapp-verify-token",
        "hub.challenge" => "challenge-value"
      })

    assert response(conn, 200) == "challenge-value"
  end

  test "rejects an invalid verification token", %{conn: conn} do
    conn =
      get(conn, ~p"/webhooks/whatsapp", %{
        "hub.mode" => "subscribe",
        "hub.verify_token" => "wrong-token",
        "hub.challenge" => "challenge-value"
      })

    assert response(conn, 403) == "forbidden"
  end

  test "rejects verification when the token is not configured", %{conn: conn} do
    Application.put_env(:nila, NilaWeb.Webhooks.WhatsAppController,
      app_secret: @secret,
      verify_token: ""
    )

    conn =
      get(conn, ~p"/webhooks/whatsapp", %{
        "hub.mode" => "subscribe",
        "hub.verify_token" => "",
        "hub.challenge" => "challenge-value"
      })

    assert response(conn, 403) == "forbidden"
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

  test "routes each phone-number ID in a batch to its own organisation", %{conn: conn} do
    first_org = Nila.AccountsFixtures.org_fixture()
    second_org = Nila.AccountsFixtures.org_fixture()

    {:ok, first_connection} =
      Integrations.upsert_connection(%{
        org_id: first_org.id,
        provider: "whatsapp",
        external_account_id: "phone-1",
        credentials: %{"access_token" => "first-token"}
      })

    {:ok, second_connection} =
      Integrations.upsert_connection(%{
        org_id: second_org.id,
        provider: "whatsapp",
        external_account_id: "phone-2",
        credentials: %{"access_token" => "second-token"}
      })

    body = Jason.encode!(batched_payload())

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", signature(body))
      |> post(~p"/webhooks/whatsapp", body)

    assert json_response(conn, 200) == %{"ok" => true}
    jobs = Oban.Job |> Repo.all() |> Enum.sort_by(& &1.id)

    assert Enum.map(jobs, & &1.args["connection_id"]) == [
             first_connection.id,
             second_connection.id
           ]

    assert get_in(Enum.at(jobs, 0).args, [
             "payload",
             "entry",
             Access.at(0),
             "changes",
             Access.at(0),
             "value",
             "messages",
             Access.at(0),
             "id"
           ]) == "wamid.phone-1"

    assert get_in(Enum.at(jobs, 1).args, [
             "payload",
             "entry",
             Access.at(0),
             "changes",
             Access.at(0),
             "value",
             "messages",
             Access.at(0),
             "id"
           ]) == "wamid.phone-2"
  end

  test "returns 503 so Meta retries when the ingest job cannot be enqueued", %{conn: conn} do
    org =
      Orgs.create_org!(%{
        name: "WhatsApp Retry Test Co",
        legal_name: "WhatsApp Retry Test Company",
        gstin: "29ABCDE1234F1ZW"
      })

    {:ok, _connection} =
      Integrations.upsert_connection(%{
        org_id: org.id,
        provider: "whatsapp",
        status: "active",
        external_account_id: "12345",
        credentials: %{"access_token" => "whatsapp-token"}
      })

    Application.put_env(:nila, :whatsapp_job_inserter, FailingInserter)
    body = Jason.encode!(payload())

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", signature(body))
      |> post(~p"/webhooks/whatsapp", body)

    assert response(conn, 503) == "webhook unavailable"
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  defp signature(body) do
    "sha256=" <>
      (:crypto.mac(:hmac, :sha256, @secret, body)
       |> Base.encode16(case: :lower))
  end

  defp batched_payload do
    %{
      "entry" => [
        %{
          "changes" => [
            %{
              "value" => %{
                "metadata" => %{"phone_number_id" => "phone-1"},
                "messages" => [
                  %{"id" => "wamid.phone-1", "text" => %{"body" => "first"}, "from" => "1"}
                ]
              }
            },
            %{
              "value" => %{
                "metadata" => %{"phone_number_id" => "phone-2"},
                "messages" => [
                  %{"id" => "wamid.phone-2", "text" => %{"body" => "second"}, "from" => "2"}
                ]
              }
            }
          ]
        }
      ]
    }
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
