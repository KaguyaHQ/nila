defmodule Nila.Gst.Chase.SenderTest do
  use Nila.DataCase, async: true
  use Oban.Testing, repo: Nila.Repo

  import Nila.AccountsFixtures

  alias Nila.Clients
  alias Nila.Gst.Chase
  alias Nila.Gst.Chase.Sender, as: ChaseSender
  alias Nila.Integrations

  @period "2026-06"
  @draft "Please send the missing Ravi Metals bill."

  test "WhatsApp sends the configured template and records the automated ask" do
    org = org_fixture()
    connection = connection!(org, "whatsapp", "phone-number-123")

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Ravi Traders",
        type: "company",
        phone: "9876543210",
        chase_channel: "whatsapp"
      })

    Req.Test.expect(Nila.Integrations.WhatsApp, fn conn ->
      assert conn.request_path == "/v20.0/#{connection.external_account_id}/messages"
      {:ok, bytes, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(bytes)

      assert payload["to"] == "919876543210"
      assert payload["type"] == "template"
      assert get_in(payload, ["template", "name"]) == "nila_document_chase"

      assert get_in(payload, [
               "template",
               "components",
               Access.at(0),
               "parameters",
               Access.at(0),
               "text"
             ]) ==
               @draft

      Req.Test.json(conn, %{"messages" => [%{"id" => "wamid.123"}]})
    end)

    assert :ok = perform_job(ChaseSender, args(org, client, "whatsapp"))
    assert [ask] = Chase.list_asks(org.id, client.id, @period)
    assert ask.channel == "whatsapp"
    assert is_nil(ask.sent_by_id)
    assert ask.body == @draft
  end

  test "email sends RFC 2822 plain text through Gmail and records the ask" do
    org = org_fixture()
    _connection = connection!(org, "gmail", "firm@example.com")

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Ravi Traders",
        type: "company",
        email: "ravi@example.com",
        chase_channel: "email"
      })

    Req.Test.expect(Nila.Integrations.Gmail, fn conn ->
      assert conn.request_path == "/gmail/v1/users/me/messages/send"
      {:ok, bytes, conn} = Plug.Conn.read_body(conn)
      %{"raw" => encoded} = Jason.decode!(bytes)
      {:ok, message} = Base.url_decode64(encoded, padding: false)

      assert message =~ "To: ravi@example.com"
      assert message =~ "Subject: Documents for June 2026 GST — #{org.name}"
      assert message =~ "Content-Type: text/plain; charset=UTF-8"
      assert message =~ @draft

      Req.Test.json(conn, %{"id" => "msg-123", "threadId" => "thread-123"})
    end)

    assert :ok = perform_job(ChaseSender, args(org, client, "email"))
    assert [%{channel: "email", sent_by_id: nil}] = Chase.list_asks(org.id, client.id, @period)
  end

  test "email sends through Microsoft Graph when that is the firm's mailbox" do
    org = org_fixture()
    _connection = connection!(org, "microsoft", "mail@bvccas.com")

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Ravi Traders",
        type: "company",
        email: "ravi@example.com",
        chase_channel: "email"
      })

    Req.Test.expect(Nila.Integrations.Microsoft, fn conn ->
      assert conn.request_path == "/v1.0/users/mail@bvccas.com/sendMail"
      {:ok, bytes, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(bytes)

      assert payload["saveToSentItems"] == true
      assert payload["message"]["subject"] == "Documents for June 2026 GST — #{org.name}"
      assert payload["message"]["body"]["content"] == @draft

      assert Enum.map(payload["message"]["toRecipients"], & &1["emailAddress"]["address"]) == [
               "ravi@example.com"
             ]

      Plug.Conn.send_resp(conn, 202, "")
    end)

    assert :ok = perform_job(ChaseSender, args(org, client, "email"))
    assert [%{channel: "email", sent_by_id: nil}] = Chase.list_asks(org.id, client.id, @period)
  end

  @tag :capture_log
  test "a missing connection returns an error and records no ask" do
    org = org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Ravi Traders",
        type: "company",
        phone: "9876543210",
        chase_channel: "whatsapp"
      })

    assert {:error, :no_whatsapp_connection_or_template} =
             perform_job(ChaseSender, args(org, client, "whatsapp"))

    assert Chase.list_asks(org.id, client.id, @period) == []
  end

  defp args(org, client, channel) do
    %{
      org_id: org.id,
      client_id: client.id,
      period: @period,
      kind: "missing_bills",
      body: @draft,
      channel: channel
    }
  end

  defp connection!(org, provider, external_account_id) do
    expires_at = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()

    {credentials, settings} =
      case provider do
        "microsoft" ->
          {%{"access_token" => "token", "expires_at" => expires_at},
           %{"tenant_id" => "11111111-2222-3333-4444-555555555555"}}

        _oauth ->
          {%{
             "access_token" => "token",
             "refresh_token" => "refresh",
             "expires_at" => expires_at
           }, %{}}
      end

    {:ok, connection} =
      Integrations.upsert_connection(%{
        org_id: org.id,
        provider: provider,
        external_account_id: external_account_id,
        settings: settings,
        credentials: credentials
      })

    connection
  end
end
