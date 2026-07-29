defmodule Nila.Integrations.MicrosoftTest do
  use Nila.DataCase, async: true

  use Oban.Testing, repo: Nila.Repo

  alias Nila.Integrations
  alias Nila.Integrations.{Microsoft, MicrosoftGrantWorker}
  alias Nila.Orgs
  alias Nila.Repo

  @tenant "11111111-2222-3333-4444-555555555555"
  @mailbox "mail@bvccas.com"

  setup do
    org =
      Orgs.create_org!(%{
        name: "Balaji Vasudevan and Co",
        legal_name: "Balaji Vasudevan and Company",
        gstin: "29ABCDE1234F1ZW"
      })

    %{org: org}
  end

  test "an expired app-only token is re-minted without a refresh token", %{org: org} do
    connection =
      connection!(org, credentials: %{"access_token" => "stale", "expires_at" => past()})

    refute Map.has_key?(connection.credentials, "refresh_token")

    Req.Test.expect(Microsoft, fn conn ->
      assert conn.request_path == "/#{@tenant}/oauth2/v2.0/token"
      {:ok, bytes, conn} = Plug.Conn.read_body(conn)
      form = URI.decode_query(bytes)

      assert form["grant_type"] == "client_credentials"
      assert form["scope"] == "https://graph.microsoft.com/.default"
      refute Map.has_key?(form, "refresh_token")

      Req.Test.json(conn, %{"access_token" => "minted", "expires_in" => 3600})
    end)

    assert {:ok, refreshed} = Integrations.ensure_token(connection)
    assert refreshed.credentials["access_token"] == "minted"
    assert Integrations.token_fresh?(refreshed.credentials)

    assert {:ok, reused} = Integrations.ensure_token(refreshed)
    assert reused.credentials["access_token"] == "minted"
  end

  test "minting replaces credentials rather than accreting stale keys", %{org: org} do
    connection =
      connection!(org,
        credentials: %{
          "access_token" => "stale",
          "expires_at" => past(),
          "refresh_token" => "does-not-belong-here",
          "scope" => "an-old-scope"
        }
      )

    Req.Test.expect(Microsoft, fn conn ->
      Req.Test.json(conn, %{"access_token" => "minted", "expires_in" => 3600})
    end)

    assert {:ok, minted} = Integrations.ensure_token(connection)
    assert Map.keys(minted.credentials) |> Enum.sort() == ["access_token", "expires_at"]
  end

  test "a token response without an expiry errors rather than looping", %{org: org} do
    connection =
      connection!(org, credentials: %{"access_token" => "stale", "expires_at" => past()})

    Req.Test.expect(Microsoft, fn conn ->
      Req.Test.json(conn, %{"access_token" => "minted"})
    end)

    assert {:error, :missing_expires_in} = Integrations.ensure_token(connection)
  end

  test "a rejected tenant surfaces the token error", %{org: org} do
    connection =
      connection!(org, credentials: %{"access_token" => "stale", "expires_at" => past()})

    Req.Test.expect(Microsoft, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(400, Jason.encode!(%{"error" => "unauthorized_client"}))
    end)

    assert {:error, {:microsoft_token_error, 400, %{"error" => "unauthorized_client"}}} =
             Integrations.ensure_token(connection)
  end

  test "sending without a live token errors rather than raising", %{org: org} do
    connection = connection!(org, credentials: %{})

    assert {:error, :missing_access_token} =
             Microsoft.send_message(connection, "kannan@caltech.example", %{
               subject: "Required GST data",
               body: "Kindly share the GST data."
             })
  end

  test "a connection with no tenant errors instead of raising", %{org: org} do
    connection =
      connection!(org,
        tenant_id: nil,
        credentials: %{"access_token" => "stale", "expires_at" => past()}
      )

    assert {:error, :missing_tenant_id} = Integrations.ensure_token(connection)
  end

  test "sends from the firm mailbox, saves to Sent, and carries cc plus reply-to", %{org: org} do
    connection =
      connection!(org,
        settings: %{
          "cc" => ["balaji@bvccas.com", "vijayan@bvccas.com"],
          "reply_to" => "caltech.bvc@nila.tax"
        }
      )

    Req.Test.expect(Microsoft, fn conn ->
      assert conn.request_path == "/v1.0/users/#{@mailbox}/sendMail"
      {:ok, bytes, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(bytes)

      assert payload["saveToSentItems"] == true

      message = payload["message"]
      assert message["subject"] == "Required GST data"
      assert message["body"]["content"] =~ "Kindly share"

      assert Enum.map(message["toRecipients"], & &1["emailAddress"]["address"]) == [
               "kannan@caltech.example"
             ]

      assert Enum.map(message["ccRecipients"], & &1["emailAddress"]["address"]) == [
               "balaji@bvccas.com",
               "vijayan@bvccas.com"
             ]

      assert Enum.map(message["replyTo"], & &1["emailAddress"]["address"]) == [
               "caltech.bvc@nila.tax"
             ]

      Plug.Conn.send_resp(conn, 202, "")
    end)

    assert {:ok, %{mailbox: @mailbox}} =
             Microsoft.send_message(connection, "kannan@caltech.example", %{
               subject: "Required GST data",
               body: "Kindly share the GST data for June 2026."
             })
  end

  test "a mailbox the app may not send as surfaces the Graph error", %{org: org} do
    connection = connection!(org)

    Req.Test.expect(Microsoft, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        403,
        Jason.encode!(%{"error" => %{"code" => "ErrorAccessDenied"}})
      )
    end)

    assert {:error, {:microsoft_send_error, 403, body}} =
             Microsoft.send_message(connection, "kannan@caltech.example", %{
               subject: "Required GST data",
               body: "Kindly share the GST data."
             })

    assert get_in(body, ["error", "code"]) == "ErrorAccessDenied"
  end

  test "a grant still propagating retries instead of marking the connection broken", %{org: org} do
    connection = connection!(org, credentials: %{}, last_status: "pending")

    Req.Test.expect(Microsoft, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(400, Jason.encode!(%{"error" => "unauthorized_client"}))
    end)

    assert {:error, _reason} =
             perform_job(MicrosoftGrantWorker, %{"connection_id" => connection.id}, attempt: 1)

    assert Repo.reload!(connection).last_status == "pending"

    Req.Test.expect(Microsoft, fn conn ->
      Req.Test.json(conn, %{"access_token" => "minted", "expires_in" => 3600})
    end)

    assert :ok =
             perform_job(MicrosoftGrantWorker, %{"connection_id" => connection.id}, attempt: 2)

    connection = Repo.reload!(connection)
    assert connection.last_status == "connected"
    assert connection.credentials["access_token"] == "minted"
  end

  test "an exhausted grant confirmation reports the connection as broken", %{org: org} do
    connection = connection!(org, credentials: %{})

    Req.Test.expect(Microsoft, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(400, Jason.encode!(%{"error" => "unauthorized_client"}))
    end)

    assert {:error, _reason} =
             perform_job(MicrosoftGrantWorker, %{"connection_id" => connection.id},
               attempt: 6,
               max_attempts: 6
             )

    assert Repo.reload!(connection).status == "error"
  end

  test "the admin consent url carries the signed state" do
    url = Microsoft.admin_consent_url("signed-state-token")
    assert %URI{host: "login.microsoftonline.com", path: "/common/adminconsent"} = URI.parse(url)

    assert URI.decode_query(URI.parse(url).query)["state"] == "signed-state-token"
  end

  defp connection!(org, opts \\ []) do
    credentials =
      Keyword.get(opts, :credentials, %{"access_token" => "token", "expires_at" => future()})

    {:ok, connection} =
      Integrations.upsert_connection(%{
        org_id: org.id,
        provider: "microsoft",
        external_account_id: @mailbox,
        tenant_id: Keyword.get(opts, :tenant_id, @tenant),
        last_status: Keyword.get(opts, :last_status, "connected"),
        credentials: credentials,
        settings: Keyword.get(opts, :settings, %{})
      })

    connection
  end

  defp past, do: DateTime.utc_now() |> DateTime.add(-60) |> DateTime.to_iso8601()
  defp future, do: DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()
end
