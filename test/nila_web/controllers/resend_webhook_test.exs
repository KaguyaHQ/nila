defmodule NilaWeb.ResendWebhookTest do
  use NilaWeb.ConnCase, async: false

  defmodule FailingInserter do
    def insert(_changeset), do: {:error, :database_unavailable}
  end

  alias Nila.Repo

  @secret_bytes "resend-webhook-secret-bytes-32!!"
  @msg_id "msg_2abc"

  setup do
    inserter = Application.get_env(:nila, :resend_job_inserter)
    config = Application.get_env(:nila, NilaWeb.Webhooks.ResendController)

    Application.put_env(:nila, NilaWeb.Webhooks.ResendController,
      signing_secret: "whsec_" <> Base.encode64(@secret_bytes)
    )

    on_exit(fn ->
      Application.put_env(:nila, NilaWeb.Webhooks.ResendController, config)

      if inserter do
        Application.put_env(:nila, :resend_job_inserter, inserter)
      else
        Application.delete_env(:nila, :resend_job_inserter)
      end
    end)

    :ok
  end

  test "a signed inbound email is enqueued for ingestion", %{conn: conn} do
    body = Jason.encode!(payload())

    conn = post_signed(conn, body)

    assert json_response(conn, 200) == %{"ok" => true}

    assert [%Oban.Job{worker: "Nila.Integrations.ResendInboundWorker"} = job] =
             Repo.all(Oban.Job)

    assert job.args["email_id"] == "email_abc123"
    assert job.args["to"] == ["n.7.42.202608.abcdef123456@inbound.nila.tax"]
    assert job.args["from"] == "Ravi <ravi@example.com>"
  end

  test "the same delivery retried by Resend enqueues once", %{conn: conn} do
    body = Jason.encode!(payload())

    post_signed(conn, body)
    post_signed(conn, body)

    assert Repo.aggregate(Oban.Job, :count) == 1
  end

  test "an unsigned request is rejected", %{conn: conn} do
    body = Jason.encode!(payload())

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/webhooks/resend", body)

    assert response(conn, 401) == "invalid signature"
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "a request signed with the wrong secret is rejected", %{conn: conn} do
    body = Jason.encode!(payload())
    timestamp = System.system_time(:second)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("svix-id", @msg_id)
      |> put_req_header("svix-timestamp", to_string(timestamp))
      |> put_req_header("svix-signature", "v1," <> Base.encode64("nope"))
      |> post(~p"/webhooks/resend", body)

    assert response(conn, 401) == "invalid signature"
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "a replayed request with a stale timestamp is rejected", %{conn: conn} do
    body = Jason.encode!(payload())
    stale = System.system_time(:second) - 3600

    conn = post_signed(conn, body, timestamp: stale)

    assert response(conn, 401) == "invalid signature"
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "a tampered body no longer matches its signature", %{conn: conn} do
    body = Jason.encode!(payload())
    timestamp = System.system_time(:second)
    signature = sign(@msg_id, timestamp, body)

    tampered = Jason.encode!(payload(%{"email_id" => "email_other"}))

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("svix-id", @msg_id)
      |> put_req_header("svix-timestamp", to_string(timestamp))
      |> put_req_header("svix-signature", signature)
      |> post(~p"/webhooks/resend", tampered)

    assert response(conn, 401) == "invalid signature"
  end

  test "one matching signature among several versions passes", %{conn: conn} do
    body = Jason.encode!(payload())
    timestamp = System.system_time(:second)
    signature = "v1," <> Base.encode64("old") <> " " <> sign(@msg_id, timestamp, body)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("svix-id", @msg_id)
      |> put_req_header("svix-timestamp", to_string(timestamp))
      |> put_req_header("svix-signature", signature)
      |> post(~p"/webhooks/resend", body)

    assert json_response(conn, 200) == %{"ok" => true}
  end

  test "an event we do not handle is acknowledged without enqueueing", %{conn: conn} do
    body = Jason.encode!(%{"type" => "email.delivered", "data" => %{"email_id" => "email_x"}})

    conn = post_signed(conn, body)

    assert json_response(conn, 200) == %{"ok" => true}
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "a webhook we cannot enqueue asks Resend to retry", %{conn: conn} do
    Application.put_env(:nila, :resend_job_inserter, FailingInserter)
    body = Jason.encode!(payload())

    conn = post_signed(conn, body)

    assert response(conn, 503) == "webhook unavailable"
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "an unconfigured webhook refuses rather than trusting the payload", %{conn: conn} do
    Application.put_env(:nila, NilaWeb.Webhooks.ResendController, signing_secret: nil)
    body = Jason.encode!(payload())

    conn = post_signed(conn, body)

    assert response(conn, 503) == "webhook unavailable"
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  defp post_signed(conn, body, opts \\ []) do
    timestamp = Keyword.get(opts, :timestamp, System.system_time(:second))

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("svix-id", @msg_id)
    |> put_req_header("svix-timestamp", to_string(timestamp))
    |> put_req_header("svix-signature", sign(@msg_id, timestamp, body))
    |> post(~p"/webhooks/resend", body)
  end

  defp sign(id, timestamp, body) do
    signature =
      :hmac
      |> :crypto.mac(:sha256, @secret_bytes, "#{id}.#{timestamp}.#{body}")
      |> Base.encode64()

    "v1," <> signature
  end

  defp payload(overrides \\ %{}) do
    %{
      "type" => "email.received",
      "data" =>
        Map.merge(
          %{
            "email_id" => "email_abc123",
            "to" => ["n.7.42.202608.abcdef123456@inbound.nila.tax"],
            "from" => "Ravi <ravi@example.com>",
            "subject" => "Re: Documents for August 2026 GST",
            "text" => "PFA the purchase bills."
          },
          overrides
        )
    }
  end
end
