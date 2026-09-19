defmodule Nila.Gst.PortalRefreshTest do
  use Nila.DataCase, async: false
  use Oban.Testing, repo: Nila.Repo
  import Nila.AccountsFixtures
  alias Nila.{Repo, Gst.Portal}
  alias Nila.Gst.Portal.{Connection, RefreshWorker}
  alias Nila.Integrations.Whitebooks

  setup do
    previous = Application.get_env(:nila, Whitebooks)

    Application.put_env(:nila, Whitebooks,
      client_id: "test",
      client_secret: "secret",
      email: "test@example.test",
      req_options: [plug: {Req.Test, Whitebooks}]
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:nila, Whitebooks, previous),
        else: Application.delete_env(:nila, Whitebooks)
    end)

    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Nila.Clients.create_client(%{
        org_id: org.id,
        name: "Refresh client",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    connection =
      Repo.insert!(%Connection{
        client_id: client.id,
        gstin: client.gstin,
        username: "gst-user",
        credentials: %{"txn" => "saved-session", "ip_address" => "203.0.113.1"},
        authorized_at: DateTime.add(DateTime.utc_now(), -7, :hour)
      })

    %{connection: connection, org: org, client: client, scope: Nila.Accounts.Scope.for_user(user)}
  end

  test "an old login refreshes once and stale callers reuse its persisted token", %{connection: c} do
    refute Portal.session_expired?(c, DateTime.utc_now())
    expect_refresh(%{"status_cd" => "1"})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %{txn: "saved-session"}} = Portal.account(c)
      end)

    refute log =~ "saved-session"
    saved = Repo.reload!(c)
    assert saved.authorized_at == c.authorized_at
    refute Portal.refresh_due?(saved)
    assert saved.credentials["refreshed_at"]
    assert {:ok, %{txn: "saved-session"}} = Portal.account(c)
  end

  test "refresh persists replacement txn and the next request uses it", %{
    connection: c,
    org: org,
    client: client
  } do
    expect_refresh(%{"status_cd" => "1", "txn" => "replacement"})

    Req.Test.expect(Whitebooks, fn conn ->
      assert conn.request_path == "/notices/noticedetails"
      assert Plug.Conn.get_req_header(conn, "txn") == ["replacement"]
      Req.Test.json(conn, %{"status_cd" => "1", "data" => %{}})
    end)

    assert {:ok, _} = Portal.notice_details(org.id, client.id, "REF")
    assert Repo.reload!(c).credentials["txn"] == "replacement"
  end

  test "transient failures retain the login and can be retried", %{connection: c} do
    Req.Test.expect(Whitebooks, fn conn -> Req.Test.transport_error(conn, :timeout) end)
    assert {:error, :unavailable} = Portal.account(c)
    refute Portal.session_expired?(Repo.reload!(c), DateTime.utc_now())
    assert Repo.reload!(c).credentials == c.credentials
    expect_refresh(%{"status_cd" => "1"})
    assert {:ok, _} = Portal.account(c)
  end

  test "provider authentication rejection persists until successful OTP verification", %{
    connection: c,
    scope: scope,
    client: client,
    org: org
  } do
    expect_refresh(%{"status_cd" => "0", "error" => %{"errorCode" => "RET11407"}})
    assert {:error, :session_expired} = Portal.account(c)
    assert Portal.session_expired?(Repo.reload!(c), DateTime.utc_now())
    assert {:error, :session_expired} = Portal.account(c)

    challenge = %Portal.Challenge{
      org_id: org.id,
      client_id: client.id,
      requested_at: DateTime.utc_now(),
      account: %{
        gstin: client.gstin,
        username: "gst-user",
        txn: "new-login",
        ip_address: "203.0.113.1"
      }
    }

    Req.Test.expect(Whitebooks, fn conn -> Req.Test.json(conn, %{"status_cd" => "1"}) end)
    assert {:ok, saved} = Portal.verify_otp(scope, challenge, "123456")
    refute Portal.session_expired?(saved, DateTime.utc_now())
    assert {:ok, %{txn: "new-login"}} = Portal.account(c)
  end

  test "early token rejection refreshes and retries the read once", %{
    connection: c,
    org: org,
    client: client
  } do
    Repo.update!(Ecto.Changeset.change(c, authorized_at: DateTime.utc_now()))

    Req.Test.expect(Whitebooks, fn conn ->
      Req.Test.json(conn, %{"status_cd" => "0", "error" => %{"errorCode" => "WB_ERR_9503"}})
    end)

    expect_refresh(%{"status_cd" => "1"})

    Req.Test.expect(Whitebooks, fn conn ->
      Req.Test.json(conn, %{"status_cd" => "1", "data" => %{}})
    end)

    assert {:ok, _} = Portal.notice_details(org.id, client.id, "REF")
    refute Portal.session_expired?(Repo.reload!(c), DateTime.utc_now())
  end

  test "a repeated auth failure after refresh requires OTP without a retry loop", %{
    org: org,
    client: client,
    connection: c
  } do
    expect_refresh(%{"status_cd" => "1"})

    Req.Test.expect(Whitebooks, fn conn ->
      Req.Test.json(conn, %{"status_cd" => "0", "error" => %{"errorCode" => "RET11407"}})
    end)

    expect_refresh(%{"status_cd" => "1"})

    Req.Test.expect(Whitebooks, fn conn ->
      Req.Test.json(conn, %{"status_cd" => "0", "error" => %{"errorCode" => "RET11407"}})
    end)

    assert {:error, :session_expired} = Portal.notice_details(org.id, client.id, "REF")
    assert Portal.session_expired?(Repo.reload!(c), DateTime.utc_now())
  end

  test "scheduled sweep deduplicates due accounts and worker renews before expiry", %{
    connection: c,
    org: org,
    client: client
  } do
    Repo.update!(
      Ecto.Changeset.change(c, authorized_at: DateTime.add(DateTime.utc_now(), -5, :hour))
    )

    assert :ok = perform_job(RefreshWorker, %{})
    assert :ok = perform_job(RefreshWorker, %{})

    assert [%{args: %{"org_id" => org_id, "client_id" => client_id}}] =
             all_enqueued(worker: RefreshWorker)

    assert org_id == org.id and client_id == client.id
    expect_refresh(%{"status_cd" => "1"})
    assert :ok = perform_job(RefreshWorker, %{org_id: org.id, client_id: client.id})
    refute Portal.refresh_due?(Repo.reload!(c))
  end

  test "no requests for fresh, disconnected or changed-GSTIN sessions", %{
    connection: c,
    client: client
  } do
    fresh = Repo.update!(Ecto.Changeset.change(c, authorized_at: DateTime.utc_now()))
    assert :ok = perform_job(RefreshWorker, %{})
    assert [] == all_enqueued(worker: RefreshWorker)
    assert {:ok, _} = Portal.account(fresh)
    Repo.update!(Ecto.Changeset.change(client, gstin: "33CPWPV2650A1ZQ"))
    assert {:error, :not_found} = Portal.account(c)
    Repo.delete!(c)
    assert {:error, :not_found} = Portal.account(c)
  end

  defp expect_refresh(response) do
    Req.Test.expect(Whitebooks, fn conn ->
      assert conn.request_path == "/authentication/refreshtoken"
      Req.Test.json(conn, response)
    end)
  end
end
