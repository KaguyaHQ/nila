defmodule NilaWeb.NoticesLiveTest do
  use NilaWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Nila.{Clients, Repo}
  alias Nila.Integrations.Whitebooks
  alias Nila.Notices.{Check, Notice}
  alias Nila.Gst.Portal.Connection

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
        name: "Notice client",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    %{conn: log_in_user(conn, user), org: org, client: client}
  end

  test "empty state names the coverage limit and connection requirement", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _} = live(conn, ~p"/notices")

    assert has_element?(
             view,
             "#notices-coverage",
             "Some notices and orders may be missing"
           )

    assert has_element?(view, "#notices-empty", "does not confirm")
    view |> form("#notices-filter", filter: %{client_id: client.id}) |> render_change()
    assert has_element?(view, "#client-checks-summary", "1 client needs attention")
    assert has_element?(view, "#client-check-action-#{client.id}", "Connect GST")
  end

  test "connect and verify forms perform the real flow and clear OTP input", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _} = live(conn, ~p"/notices?#{%{client_id: client.id}}")
    view |> element("#client-checks > summary") |> render_click()
    view |> element("#client-check-action-#{client.id}") |> render_click()

    Req.Test.expect(Whitebooks, fn request ->
      Req.Test.json(request, %{"status_cd" => "1", "txn" => "challenge"})
    end)

    view |> form("#notice-connect-form", connection: %{username: "gst-user"}) |> render_submit()
    render_async(view)
    assert has_element?(view, "#notice-otp")
    Req.Test.expect(Whitebooks, fn request -> Req.Test.json(request, %{"status_cd" => "1"}) end)
    view |> form("#notice-otp-form", verification: %{otp: "123456"}) |> render_submit()
    render_async(view)
    refute has_element?(view, "#notice-connection-modal")

    assert has_element?(
             view,
             "#client-check-action-#{client.id}:not([disabled])",
             "Check notices"
           )

    assert Repo.get_by!(Connection, client_id: client.id).username == "gst-user"
  end

  test "detail shows source dates, document link and no claim about reply status", %{
    conn: conn,
    client: client
  } do
    notice = notice!(client)
    {:ok, view, _} = live(conn, ~p"/notices/#{notice.id}")
    assert has_element?(view, "#notice-details", "31 Jul 2026")

    assert has_element?(
             view,
             "#notice-document-0[href='/notices/#{notice.id}/documents/0']",
             "View PDF"
           )

    assert has_element?(view, "p", "Check the GST portal to see whether a reply was filed")
    assert has_element?(view, "#notices-back")
  end

  test "foreign notices and PDFs are inaccessible", %{conn: conn} do
    %{org: other} = user_with_org_fixture(%{org: %{gstin: "27ABCDE1234F1Z0"}})
    {:ok, client} = Clients.create_client(%{org_id: other.id, name: "Foreign", type: "company"})
    notice = notice!(client)
    {:ok, view, _} = live(conn, ~p"/notices")
    refute has_element?(view, "#notices-table", notice.reference)
    assert {:error, {:live_redirect, %{to: "/notices"}}} = live(conn, ~p"/notices/#{notice.id}")
    assert get(conn, ~p"/notices/#{notice.id}/documents/0").status == 404
  end

  test "viewers can read notices but cannot connect or check", %{
    conn: conn,
    client: client,
    org: org
  } do
    viewer = user_fixture()
    {:ok, _} = Nila.Orgs.add_user(org, viewer.id, "viewer")
    {:ok, view, _} = live(log_in_user(conn, viewer), ~p"/notices?#{%{client_id: client.id}}")
    assert has_element?(view, "#client-check-action-#{client.id}[disabled]", "Connect GST")
    assert has_element?(view, "#client-check-permissions", "Your role can view notices")
    render_click(view, "connect", %{"client_id" => to_string(client.id)})
    refute has_element?(view, "#notice-connection-modal")
  end

  defp notice!(client) do
    Repo.insert!(%Notice{
      client_id: client.id,
      gstin: client.gstin || "33AEWPH4158J1Z3",
      reference: "NOTICE-123",
      notice_type: "REMINDER",
      issued_on: ~D[2026-07-25],
      reply_due_on: ~D[2026-07-31],
      fetched_at: DateTime.utc_now(),
      payload: %{
        "detail" => %{
          "taxPeriod" => %{},
          "maindocs" => [
            %{
              "dcupdtls" => %{"id" => "doc", "ct" => "application/pdf", "docName" => "Notice.pdf"}
            }
          ],
          "suppdocs" => []
        }
      }
    })
  end

  test "client checks stay firm-wide while the notice filter changes", %{
    conn: conn,
    client: client,
    org: org
  } do
    {:ok, second} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Other client",
        type: "company",
        gstin: "33CPWPV2650A1ZQ"
      })

    notice!(client)
    notice!(second)
    %{org: foreign_org} = user_with_org_fixture()

    {:ok, foreign} =
      Clients.create_client(%{org_id: foreign_org.id, name: "Foreign client", type: "company"})

    {:ok, view, _} = live(conn, ~p"/notices")
    assert has_element?(view, "#client-checks-summary", "2 clients need attention")
    refute has_element?(view, "#client-check-status-#{foreign.id}")
    view |> element("#client-checks > summary") |> render_click()
    assert has_element?(view, "#client-checks[open]")
    view |> form("#notices-filter", filter: %{client_id: client.id}) |> render_change()
    assert has_element?(view, "#client-checks[open]")
    assert has_element?(view, "#client-check-status-#{second.id}", "Not connected")
    assert has_element?(view, "#client-checks-summary", "2 clients need attention")
    refute has_element?(view, "#notices-table", second.name)

    # Connecting the other client must not accidentally connect the filtered one.
    view |> element("#client-check-action-#{second.id}") |> render_click()
    assert has_element?(view, "#notice-connection-modal-title", "Other client")

    Req.Test.expect(Whitebooks, fn request ->
      assert Plug.Conn.get_req_header(request, "gst_username") == ["other-gst-user"]
      Req.Test.json(request, %{"status_cd" => "1", "txn" => "other-challenge"})
    end)

    view
    |> form("#notice-connect-form", connection: %{username: "other-gst-user"})
    |> render_submit()

    render_async(view)
    Req.Test.expect(Whitebooks, fn request -> Req.Test.json(request, %{"status_cd" => "1"}) end)
    view |> form("#notice-otp-form", verification: %{otp: "123456"}) |> render_submit()
    render_async(view)
    assert Repo.get_by(Connection, client_id: second.id)
    refute Repo.get_by(Connection, client_id: client.id)
    assert has_element?(view, "#client-checks[open]")
    assert has_element?(view, "#client-check-status-#{second.id}", "Not checked yet")
  end

  test "expired login keeps its successful check time and differs from a failed check", %{
    conn: conn,
    client: client,
    org: org
  } do
    {:ok, failed} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Failed client",
        type: "company",
        gstin: "33CPWPV2650A1ZQ"
      })

    checked_at = ~U[2026-08-01 04:30:00.000000Z]

    connection!(client,
      authorized_at: DateTime.add(DateTime.utc_now(), -21_601),
      last_checked_at: checked_at
    )

    connection!(failed,
      last_error: "Could not complete the GST request.",
      last_checked_at: checked_at
    )

    {:ok, view, _} = live(conn, ~p"/notices")
    assert has_element?(view, "#client-check-status-#{client.id}", "Login expired")
    refute has_element?(view, "#client-check-status-#{client.id}.text-error")
    assert has_element?(view, "#client-check-time-#{client.id}", "01 Aug 2026 at 10:00 IST")
    assert has_element?(view, "#client-check-action-#{client.id}", "Reconnect GST")
    assert has_element?(view, "#client-check-status-#{failed.id}.text-error", "Check failed")
    assert has_element?(view, "#client-check-action-#{failed.id}", "Try again")
  end

  test "row checks queue the row client and keep the expanded section open", %{
    conn: conn,
    client: client,
    org: org
  } do
    connection!(client)
    {:ok, view, _} = live(conn, ~p"/notices")
    view |> element("#client-checks > summary") |> render_click()
    view |> element("#client-check-action-#{client.id}") |> render_click()
    assert Nila.Notices.checking?(org.id, client.id)
    assert has_element?(view, "#client-check-action-#{client.id}[disabled]", "Checking")
    assert has_element?(view, "#client-checks[open]")
  end

  test "clients missing GSTIN get an edit link; successful checks do not need attention", %{
    conn: conn,
    client: client,
    org: org
  } do
    {:ok, missing} =
      Clients.create_client(%{org_id: org.id, name: "Missing GSTIN", type: "company"})

    connection!(client, last_checked_at: DateTime.utc_now())
    {:ok, view, _} = live(conn, ~p"/notices")
    assert has_element?(view, "#client-check-status-#{client.id}", "Checked successfully")
    assert has_element?(view, "#client-checks-summary", "1 client needs attention")

    assert has_element?(
             view,
             "#client-check-action-#{missing.id}[href='/clients/#{missing.id}/edit']",
             "Add GSTIN"
           )

    refute has_element?(view, "#client-check-status-#{missing.id}.text-error")
  end

  defp connection!(client, attrs \\ []) do
    {check_attrs, attrs} = Keyword.split(attrs, [:last_checked_at, :last_error])

    if check_attrs != [],
      do: Repo.insert!(struct!(Check, [client_id: client.id, gstin: client.gstin] ++ check_attrs))

    struct!(
      Connection,
      [
        client_id: client.id,
        gstin: client.gstin,
        username: "gst-user",
        credentials: %{"txn" => "test-session", "ip_address" => "203.0.113.1"},
        authorized_at: DateTime.utc_now()
      ] ++ attrs
    )
    |> Repo.insert!()
  end
end
