defmodule NilaWeb.Gst.Gstr2bLiveTest do
  use NilaWeb.ConnCase, async: false
  use Oban.Testing, repo: Nila.Repo
  import Phoenix.LiveViewTest
  alias Nila.{Clients, Repo}
  alias Nila.Accounts.Scope
  alias Nila.Gst.Portal.{Connection, Gstr2b, Statement, StatementWorker}
  alias Nila.Integrations.Whitebooks

  setup %{conn: conn} do
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
        name: "Statement client",
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

    %{
      conn: log_in_user(conn, user),
      scope: Scope.for_user(user),
      org: org,
      client: client,
      connection: connection
    }
  end

  defp document(gstin) do
    %{
      "chksum" => "source-checksum",
      "data" => %{
        "gstin" => gstin,
        "rtnprd" => "072026",
        "gendt" => "14-08-2026",
        "version" => "1.0",
        "docdata" => %{"b2b" => []}
      }
    }
  end

  defp expect_document(client, overrides \\ %{}) do
    Req.Test.expect(Whitebooks, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.request_path == "/gstr2b/all"

      assert conn.query_params == %{
               "gstin" => client.gstin,
               "rtnprd" => "072026",
               "email" => "test@example.test"
             }

      assert Plug.Conn.get_req_header(conn, "txn") == ["private-session"]
      assert Plug.Conn.get_req_header(conn, "gst_username") == ["gst-user"]

      Req.Test.json(
        conn,
        Map.merge(
          %{"status_cd" => "1", "data" => document(client.gstin), "txn" => "must-not-save"},
          overrides
        )
      )
    end)
  end

  test "fetch, save and download through the screen; another firm cannot download", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _} = live(conn, ~p"/gst/2b?#{%{client_id: client.id, period: "2026-07"}}")
    assert has_element?(view, "#gstr2b-empty")
    expect_document(client)
    view |> form("#gstr2b-form") |> render_submit()
    assert has_element?(view, "#gstr2b-fetch[disabled]")
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :workflows)
    assert has_element?(view, "#gstr2b-download")
    assert has_element?(view, "#gstr2b-fetched-at", "Fetched")
    statement = Repo.one!(Statement)
    assert statement.document == document(client.gstin)
    download = get(conn, ~p"/gst/2b/statements/#{statement.id}/download")
    assert Jason.decode!(response(download, 200)) == document(client.gstin)
    assert get_resp_header(download, "cache-control") == ["private, no-store"]

    assert hd(get_resp_header(download, "content-disposition")) =~
             "GSTR2B_#{client.gstin}_2026-07.json"

    %{user: other} = user_with_org_fixture()

    denied =
      build_conn() |> log_in_user(other) |> get(~p"/gst/2b/statements/#{statement.id}/download")

    assert response(denied, 404)
  end

  test "duplicate clicks share a job and failed refresh retains the previous download", %{
    scope: scope,
    client: client
  } do
    expect_document(client)
    assert {:ok, first} = Gstr2b.enqueue(scope, client.id, "2026-07")
    assert {:ok, duplicate} = Gstr2b.enqueue(scope, client.id, "2026-07")
    assert first.id == duplicate.id
    assert %{success: 1} = Oban.drain_queue(queue: :workflows)
    saved = Repo.one!(Statement)
    Req.Test.expect(Whitebooks, fn conn -> Req.Test.transport_error(conn, :timeout) end)
    assert {:ok, _} = Gstr2b.enqueue(scope, client.id, "2026-07")
    assert %{discard: 1} = Oban.drain_queue(queue: :workflows)
    failed = Repo.reload!(saved)
    assert failed.status == "failed"
    assert failed.document == saved.document
    assert failed.fetched_at == saved.fetched_at
    refute Gstr2b.fetching?(failed)
    assert {:ok, _, _} = Gstr2b.download(scope, saved.id)
  end

  test "wrong GSTIN, month, incomplete and multi-file responses cannot replace a saved document",
       %{scope: scope, client: client} do
    for data <- [
          put_in(document(client.gstin), ["data", "gstin"], "33AALCK1118R1Z8"),
          put_in(document(client.gstin), ["data", "rtnprd"], "082026"),
          %{"data" => %{"gstin" => client.gstin, "rtnprd" => "072026"}},
          %{"fc" => 2}
        ] do
      expect_document(client, %{"data" => data})
      assert {:ok, _} = Gstr2b.enqueue(scope, client.id, "2026-07")
      assert %{discard: 1} = Oban.drain_queue(queue: :workflows)
      assert Repo.one!(Statement).document == nil
    end
  end

  test "expired and changed GST sessions stop requests; invalid month and foreign client are rejected",
       %{scope: scope, client: client, connection: connection} do
    assert {:error, :invalid_period} = Gstr2b.enqueue(scope, client.id, "2026-13")
    assert {:error, :invalid_period} = Gstr2b.enqueue(scope, client.id, "2026-7")
    %{user: other} = user_with_org_fixture()
    assert {:error, :not_found} = Gstr2b.enqueue(Scope.for_user(other), client.id, "2026-07")

    connection
    |> Ecto.Changeset.change(authorized_at: DateTime.add(DateTime.utc_now(), -7, :hour))
    |> Repo.update!()

    assert {:error, :session_expired} = Gstr2b.enqueue(scope, client.id, "2026-07")
    assert Repo.aggregate(Statement, :count) == 0
  end

  test "GSTIN changed after enqueue never fetches under the new identity", %{
    scope: scope,
    client: client,
    connection: connection
  } do
    {:ok, _} = Gstr2b.enqueue(scope, client.id, "2026-07")
    client |> Ecto.Changeset.change(gstin: "33AALCK1118R1Z8") |> Repo.update!()
    connection |> Ecto.Changeset.change(gstin: "33AALCK1118R1Z8") |> Repo.update!()
    assert %{discard: 1} = Oban.drain_queue(queue: :workflows)
    assert Repo.one!(Statement).document == nil
  end

  test "viewer can download but cannot enqueue, even with a forged event", %{
    conn: conn,
    scope: scope,
    client: client
  } do
    viewer = %{scope | membership: %{scope.membership | role: "viewer"}}
    assert {:error, :forbidden} = Gstr2b.enqueue(viewer, client.id, "2026-07")
    Repo.update!(Ecto.Changeset.change(scope.membership, role: "viewer"))
    {:ok, view, _} = live(conn, ~p"/gst/2b?#{%{client_id: client.id, period: "2026-07"}}")
    assert has_element?(view, "#gstr2b-fetch[disabled]")

    render_submit(view, "fetch", %{
      "statement" => %{"client_id" => to_string(client.id), "period" => "2026-07"}
    })

    assert has_element?(view, "#gstr2b-error", "Your role")
    assert [] == all_enqueued(worker: StatementWorker)

    statement =
      Repo.insert!(%Statement{
        client_id: client.id,
        gstin: client.gstin,
        period: "2026-07",
        document: document(client.gstin),
        fetched_at: DateTime.utc_now(),
        status: "ready"
      })

    assert get(conn, ~p"/gst/2b/statements/#{statement.id}/download") |> response(200)
  end

  test "missing session opens authentication inside the fetch task", %{
    conn: conn,
    connection: connection,
    client: client
  } do
    Repo.delete!(connection)
    {:ok, view, _} = live(conn, ~p"/gst/2b?#{%{client_id: client.id}}")
    refute has_element?(view, "#gstr2b-connection a")
    assert has_element?(view, "#gstr2b-fetch:not([disabled])")
    view |> form("#gstr2b-form") |> render_submit()
    assert has_element?(view, "#gst-connection-modal")
    assert has_element?(view, "#gst-connection-identity", client.gstin)
  end

  test "reconnect resumes the chosen month, retains a pending OTP on close, and never fetches after a failed OTP",
       %{conn: conn, connection: connection, client: client} do
    connection
    |> Ecto.Changeset.change(authorized_at: DateTime.add(DateTime.utc_now(), -7, :hour))
    |> Repo.update!()

    {:ok, view, _} = live(conn, ~p"/gst/2b?#{%{client_id: client.id, period: "2026-07"}}")
    assert has_element?(view, "#gstr2b-connection", "session expired")
    view |> form("#gstr2b-form") |> render_submit()
    assert has_element?(view, "#gst-username[value='gst-user']")

    Req.Test.expect(Whitebooks, fn request ->
      assert request.request_path == "/authentication/otprequest"
      Req.Test.json(request, %{"status_cd" => "1", "txn" => "new-challenge"})
    end)

    view |> form("#gst-connect-form", connection: %{username: "gst-user"}) |> render_submit()
    render_async(view, 1000)
    assert has_element?(view, "#gst-connect-submit", "Verify and fetch")
    view |> element("#gst-connection-close") |> render_click()
    refute has_element?(view, "#gst-connection-modal")
    view |> form("#gstr2b-form") |> render_submit()
    assert has_element?(view, "#gst-otp-form")

    Req.Test.expect(Whitebooks, fn request ->
      Req.Test.json(request, %{"status_cd" => "0", "error" => %{"errorCode" => "WB_ERR_9101"}})
    end)

    view |> form("#gst-otp-form", verification: %{otp: "123456"}) |> render_submit()
    render_async(view, 1000)
    assert has_element?(view, "#gst-connection-error")
    assert [] == all_enqueued(worker: StatementWorker)

    Req.Test.expect(Whitebooks, fn request ->
      assert request.request_path == "/authentication/otprequest"
      assert Plug.Conn.get_req_header(request, "gst_username") == ["gst-user"]
      Req.Test.json(request, %{"status_cd" => "1", "txn" => "resent-challenge"})
    end)

    view |> element("#gst-otp-resend") |> render_click()
    render_async(view, 1000)
    assert has_element?(view, "#gst-otp-form")
    assert has_element?(view, "#gst-otp-notice", "New OTP sent.")
    refute has_element?(view, "#gst-connection-error")

    Req.Test.expect(Whitebooks, fn request ->
      assert request.request_path == "/authentication/authtoken"
      assert Plug.Conn.get_req_header(request, "txn") == ["resent-challenge"]
      Req.Test.json(request, %{"status_cd" => "1"})
    end)

    view |> form("#gst-otp-form", verification: %{otp: "654321"}) |> render_submit()
    render_async(view, 1000)
    refute has_element?(view, "#gst-connection-modal")
    assert has_element?(view, "#gstr2b-period[value='2026-07']")
    assert [%{args: %{"statement_id" => id}}] = all_enqueued(worker: StatementWorker)
    assert %{client_id: client_id, period: "2026-07"} = Repo.get!(Statement, id)
    assert client_id == client.id
  end

  test "switching clients cannot reuse another client's pending OTP", %{
    conn: conn,
    org: org,
    connection: connection,
    client: client
  } do
    Repo.delete!(connection)

    {:ok, second} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Second client",
        type: "company",
        gstin: "33CPWPV2650A1ZQ"
      })

    {:ok, view, _} = live(conn, ~p"/gst/2b?#{%{client_id: client.id, period: "2026-07"}}")
    view |> form("#gstr2b-form") |> render_submit()

    Req.Test.expect(Whitebooks, fn request ->
      Req.Test.json(request, %{"status_cd" => "1", "txn" => "challenge"})
    end)

    view |> form("#gst-connect-form", connection: %{username: "first-user"}) |> render_submit()
    render_async(view, 1000)
    view |> element("#gst-change-username") |> render_click()
    assert has_element?(view, "#gst-username[value='first-user']")
    refute has_element?(view, "#gst-otp-form")
    view |> element("#gst-connection-close") |> render_click()

    view
    |> form("#gstr2b-form", statement: %{client_id: second.id, period: "2026-07"})
    |> render_change()

    view |> form("#gstr2b-form") |> render_submit()
    assert has_element?(view, "#gst-connection-identity", second.gstin)
    assert has_element?(view, "#gst-connect-form")
    refute has_element?(view, "#gst-otp-form")
  end

  test "client page manages the shared login and disconnect keeps saved statements", %{
    conn: conn,
    client: client,
    scope: scope
  } do
    statement =
      Repo.insert!(%Statement{
        client_id: client.id,
        gstin: client.gstin,
        period: "2026-07",
        document: document(client.gstin),
        fetched_at: DateTime.utc_now(),
        status: "ready"
      })

    {:ok, view, _} = live(conn, ~p"/clients/#{client.id}/edit")
    assert has_element?(view, "#client-gst-username", "gst-user")
    view |> element("#client-gst-connect") |> render_click()
    assert has_element?(view, "#gst-username[value='gst-user']")
    view |> element("#gst-connection-close") |> render_click()
    view |> element("#client-gst-disconnect") |> render_click()
    assert has_element?(view, "#client-gst-status", "Not connected")
    assert Repo.get_by(Connection, client_id: client.id) == nil
    assert {:ok, _, _} = Gstr2b.download(scope, statement.id)
  end

  test "disconnect is firm-scoped and restricted to account managers", %{
    scope: scope,
    client: client
  } do
    %{user: other} = user_with_org_fixture()
    assert {:error, :not_found} = Nila.Gst.Portal.disconnect(Scope.for_user(other), client.id)
    operator = %{scope | membership: %{scope.membership | role: "member"}}
    assert {:error, :forbidden} = Nila.Gst.Portal.disconnect(operator, client.id)
    assert Repo.get_by(Connection, client_id: client.id)
  end
end
