defmodule Nila.NoticesTest do
  use Nila.DataCase, async: false
  use Oban.Testing, repo: Nila.Repo
  import Nila.AccountsFixtures
  alias Nila.{Clients, Notices, Repo}
  alias Nila.Accounts.Scope
  alias Nila.Integrations.Whitebooks
  alias Nila.Notices.{Check, Notice, SyncWorker}
  alias Nila.Gst.Portal
  alias Nila.Gst.Portal.Connection

  setup do
    previous = Application.get_env(:nila, Whitebooks)

    Application.put_env(:nila, Whitebooks,
      client_id: "test",
      client_secret: "secret",
      email: "test@example.test",
      ip_address: "203.0.113.1",
      req_options: [plug: {Req.Test, Whitebooks}]
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:nila, Whitebooks, previous),
        else: Application.delete_env(:nila, Whitebooks)
    end)

    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Test client",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    connection =
      Repo.insert!(%Connection{
        client_id: client.id,
        gstin: client.gstin,
        username: "gst-user",
        credentials: %{"txn" => "private-session", "ip_address" => "203.0.113.1"},
        authorized_at: DateTime.utc_now()
      })

    %{org: org, client: client, connection: connection, scope: Scope.for_user(user)}
  end

  test "OTP is verified before encrypted credentials are saved", %{scope: scope, client: client} do
    Req.Test.expect(Whitebooks, fn conn ->
      assert conn.request_path == "/authentication/otprequest"
      Req.Test.json(conn, %{"status_cd" => "1", "txn" => "new-session"})
    end)

    assert {:ok, challenge} = Portal.request_otp(scope, client.id, "gst-user")
    refute inspect(challenge) =~ "new-session"

    Req.Test.expect(Whitebooks, fn conn ->
      assert conn.request_path == "/authentication/authtoken"
      Req.Test.json(conn, %{"status_cd" => "1"})
    end)

    assert {:ok, connection} = Portal.verify_otp(scope, challenge, "123456")
    assert connection.credentials["txn"] == "new-session"

    %{rows: [[stored]]} =
      Repo.query!("SELECT credentials FROM gst_portal_connections WHERE id = $1", [connection.id])

    refute stored =~ "new-session"
    refute Map.has_key?(connection.credentials, "otp")
  end

  test "failed verification preserves the previous session and missing setup stops before requesting OTP",
       %{scope: scope, client: client, connection: connection} do
    challenge = %Nila.Gst.Portal.Challenge{
      client_id: client.id,
      org_id: scope.current_org.id,
      requested_at: DateTime.utc_now(),
      account: %{
        gstin: client.gstin,
        username: "gst-user",
        ip_address: "203.0.113.1",
        txn: "rejected-session"
      }
    }

    Req.Test.expect(Whitebooks, fn conn ->
      Req.Test.json(conn, %{"status_cd" => "0", "error" => %{"errorCode" => "AUTH_001"}})
    end)

    assert {:error, {:provider, "AUTH_001"}} = Portal.verify_otp(scope, challenge, "123456")
    assert Repo.get!(Connection, connection.id).credentials["txn"] == "private-session"
    config = Application.get_env(:nila, Whitebooks)
    Application.put_env(:nila, Whitebooks, Keyword.delete(config, :ip_address))
    assert {:error, :not_configured} = Portal.request_otp(scope, client.id, "gst-user")

    assert {:error, :invalid_connection} =
             Portal.request_otp(scope, client.id, String.duplicate("x", 101))
  end

  test "a different GSTIN does not inherit the old GSTIN's check time", %{
    scope: scope,
    client: client,
    connection: _connection
  } do
    Repo.insert!(%Check{
      client_id: client.id,
      gstin: client.gstin,
      last_checked_at: DateTime.utc_now()
    })

    client |> Ecto.Changeset.change(gstin: "33CPWPV2650A1ZQ") |> Repo.update!()

    challenge = %Nila.Gst.Portal.Challenge{
      client_id: client.id,
      org_id: scope.current_org.id,
      requested_at: DateTime.utc_now(),
      account: %{
        gstin: "33CPWPV2650A1ZQ",
        username: "gst-user",
        ip_address: "203.0.113.1",
        txn: "new-session"
      }
    }

    Req.Test.expect(Whitebooks, fn conn -> Req.Test.json(conn, %{"status_cd" => "1"}) end)
    assert {:ok, updated} = Portal.verify_otp(scope, challenge, "123456")
    assert updated.gstin == "33CPWPV2650A1ZQ"
    assert Notices.checks(scope.current_org.id)[client.id] == nil
  end

  test "rechecks update rather than duplicate; empty lists retain saved notices", %{
    org: org,
    client: client
  } do
    expect_notice("31/07/2026")
    assert {:ok, 1} = Notices.sync(org.id, client.id)
    [first] = Notices.list(org.id)
    assert first.reply_due_on == ~D[2026-07-31]
    expect_notice("02/08/2026")
    assert {:ok, 1} = Notices.sync(org.id, client.id)
    assert [%{id: id, reply_due_on: ~D[2026-08-02]}] = Notices.list(org.id)
    assert id == first.id

    Req.Test.expect(Whitebooks, fn conn ->
      Req.Test.json(conn, %{"status_cd" => "0", "error" => %{"errorCode" => "NOTC_010"}})
    end)

    assert {:ok, 0} = Notices.sync(org.id, client.id)
    assert length(Notices.list(org.id)) == 1
  end

  test "an empty success detail cannot overwrite saved data or the last successful check", %{
    org: org,
    client: client
  } do
    expect_notice("31/07/2026")
    assert {:ok, 1} = Notices.sync(org.id, client.id)
    checked = Notices.checks(org.id)[client.id].last_checked_at
    expect_list()

    Req.Test.expect(Whitebooks, fn conn ->
      Req.Test.json(conn, %{
        "status_cd" => "1",
        "data" => %{
          "dueDateOfReply" => "",
          "maindocs" => [],
          "suppdocs" => [],
          "taxPeriod" => %{}
        }
      })
    end)

    assert {:error, :unexpected_response} = Notices.sync(org.id, client.id)
    assert Notices.checks(org.id)[client.id].last_checked_at == checked
    assert Notices.checks(org.id)[client.id].last_error =~ "incomplete"
    assert [%{reply_due_on: ~D[2026-07-31]}] = Notices.list(org.id)
  end

  test "tenant scope applies to connections, list, details, jobs and downloads", %{
    org: org,
    client: client,
    scope: scope
  } do
    expect_notice("31/07/2026")
    assert {:ok, 1} = Notices.sync(org.id, client.id)
    [notice] = Notices.list(org.id)
    %{user: user, org: other} = user_with_org_fixture(%{org: %{gstin: "27ABCDE1234F1Z0"}})
    assert Notices.list(other.id) == []
    assert Portal.connections(other.id) == %{}
    assert {:error, :not_found} = Notices.fetch(other.id, notice.id)
    assert {:error, :not_found} = Notices.download(other.id, notice.id, 0)
    assert {:error, :not_found} = Notices.enqueue(Scope.for_user(user), client.id)
    viewer = %{scope | membership: %{scope.membership | role: "viewer"}}
    assert {:error, :forbidden} = Notices.enqueue(viewer, client.id)
    assert {:error, :forbidden} = Portal.request_otp(viewer, client.id, "gst-user")
  end

  test "expired sessions require another OTP and do not call the provider", %{
    scope: scope,
    connection: connection,
    client: client
  } do
    connection
    |> Ecto.Changeset.change(
      credentials: Map.put(connection.credentials, "reauth_required", true)
    )
    |> Repo.update!()

    assert {:error, :session_expired} = Notices.enqueue(scope, client.id)
  end

  test "repeated checks share one job", %{scope: scope, client: client, org: org} do
    assert {:ok, first} = Notices.enqueue(scope, client.id)
    assert {:ok, second} = Notices.enqueue(scope, client.id)
    assert first.id == second.id
    assert Notices.checking?(org.id, client.id)
    expect_notice("31/07/2026")
    assert :ok = perform_job(SyncWorker, %{org_id: org.id, client_id: client.id})
    assert Repo.aggregate(Notice, :count) == 1
  end

  test "PDF download uses stored document identity and rejects non-PDF bytes", %{
    org: org,
    client: client
  } do
    expect_notice("31/07/2026")
    assert {:ok, 1} = Notices.sync(org.id, client.id)
    [notice] = Notices.list(org.id)

    Req.Test.expect(Whitebooks, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.request_path == "/all/docdwld"
      assert conn.query_params["id"] == "document-id"
      assert conn.query_params["retperiod"] == "072026"

      Req.Test.json(conn, %{
        "status_cd" => "1",
        "data" => %{"ct" => "application/pdf", "data" => Base.encode64("%PDF-1.4 test")}
      })
    end)

    assert {:ok, "%PDF-1.4 test"} = Notices.download(org.id, notice.id, 0)

    Req.Test.expect(Whitebooks, fn conn ->
      Req.Test.json(conn, %{
        "status_cd" => "1",
        "data" => %{"ct" => "application/pdf", "data" => Base.encode64("<html>error</html>")}
      })
    end)

    assert {:error, :document_unavailable} = Notices.download(org.id, notice.id, 0)
  end

  test "direct retrieval saves old notices without a list request or check timestamp", %{
    scope: scope,
    client: client,
    org: org
  } do
    expect_detail("14/04/2025", "13/03/2025")
    assert {:ok, notice} = Notices.fetch_by_reference(scope, client.id, " REF-1 ")
    assert notice.issued_on == ~D[2025-03-13]
    assert notice.payload["list"] == nil
    assert Notices.checks(org.id) == %{}
    assert [%{id: id}] = Notices.list(org.id)
    assert id == notice.id

    Req.Test.expect(Whitebooks, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params["retperiod"] == "032025"

      Req.Test.json(conn, %{
        "status_cd" => "1",
        "data" => %{
          "ct" => "application/pdf",
          "data" => Base.encode64("%PDF-1.4 old notice")
        }
      })
    end)

    assert {:ok, "%PDF-1.4 old notice"} = Notices.download(org.id, notice.id, 0)
  end

  test "direct rechecks preserve list evidence and malformed details preserve the saved notice",
       %{
         scope: scope,
         client: client,
         org: org
       } do
    expect_notice("31/07/2026")
    assert {:ok, 1} = Notices.sync(org.id, client.id)
    [original] = Notices.list(org.id)
    checked = Notices.checks(org.id)[client.id].last_checked_at
    expect_detail("02/08/2026")
    assert {:ok, updated} = Notices.fetch_by_reference(scope, client.id, "REF-1")
    assert updated.id == original.id
    assert updated.reply_due_on == ~D[2026-08-02]
    assert updated.payload["list"] == original.payload["list"]

    Req.Test.expect(Whitebooks, fn conn ->
      Req.Test.json(conn, %{"status_cd" => "1", "data" => %{}})
    end)

    assert {:error, :unexpected_response} = Notices.fetch_by_reference(scope, client.id, "REF-1")
    assert [%{reply_due_on: ~D[2026-08-02]}] = Notices.list(org.id)
    assert Notices.checks(org.id)[client.id].last_checked_at == checked
  end

  test "direct retrieval rejects unauthorized, foreign, invalid and expired requests before HTTP",
       %{
         scope: scope,
         client: client,
         connection: connection
       } do
    viewer = %{scope | membership: %{scope.membership | role: "viewer"}}
    assert {:error, :forbidden} = Notices.fetch_by_reference(viewer, client.id, "REF-1")
    %{user: other} = user_with_org_fixture()

    assert {:error, :not_found} =
             Notices.fetch_by_reference(Scope.for_user(other), client.id, "REF-1")

    for invalid <- [nil, "  ", String.duplicate("x", 101)] do
      assert {:error, :invalid_reference} = Notices.fetch_by_reference(scope, client.id, invalid)
    end

    connection
    |> Ecto.Changeset.change(
      credentials: Map.put(connection.credentials, "reauth_required", true)
    )
    |> Repo.update!()

    assert {:error, :session_expired} = Notices.fetch_by_reference(scope, client.id, "REF-1")
  end

  defp expect_list do
    Req.Test.expect(Whitebooks, fn conn ->
      Req.Test.json(conn, %{
        "status_cd" => "1",
        "data" => %{"notices" => [%{"refId" => "REF-1", "dateOfRespond" => "NA"}]}
      })
    end)
  end

  defp expect_notice(due) do
    expect_list()
    expect_detail(due)
  end

  defp expect_detail(due, issued \\ "25/07/2026") do
    Req.Test.expect(Whitebooks, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.request_path == "/notices/noticedetails"
      assert conn.query_params["refId"] == "REF-1"

      Req.Test.json(conn, %{
        "status_cd" => "1",
        "data" => %{
          "noticeType" => "REMINDER",
          "dateOfIssue" => issued,
          "dueDateOfReply" => due,
          "maindocs" => [
            %{
              "dcupdtls" => %{
                "id" => "document-id",
                "docName" => "Reminder.pdf",
                "ct" => "application/pdf"
              }
            }
          ],
          "suppdocs" => [],
          "taxPeriod" => %{}
        }
      })
    end)
  end
end
