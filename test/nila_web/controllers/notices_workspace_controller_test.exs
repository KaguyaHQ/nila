defmodule NilaWeb.NoticesWorkspaceControllerTest do
  use NilaWeb.ConnCase, async: false
  import NilaWeb.ApiContract, only: [contract_response: 2]
  alias Nila.{Clients, Repo}
  alias Nila.Notices.{Notice, Run}
  alias Nila.Integrations.Whitebooks
  @base "/api/workspace/notices"

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

    %{conn: log_in_user(conn, user), user: user, org: org, client: client}
  end

  test "snapshot retains history and latest-run membership across reads", %{
    conn: conn,
    org: org,
    client: client
  } do
    old = notice!(client, "OLD")
    fresh = notice!(client, "NEW")

    Repo.insert!(%Run{
      org_id: org.id,
      baseline_notice_id: old.id,
      notice_ids: [fresh.id],
      results: %{to_string(client.id) => %{"name" => client.name, "state" => "checked"}}
    })

    for _ <- 1..2 do
      response = get(conn, @base)
      body = contract_response(response, 200)
      assert body["run"]["checked"] == 1
      assert Enum.find(body["notices"], &(&1["id"] == fresh.id))["new"]
      refute Enum.find(body["notices"], &(&1["id"] == old.id))["new"]
      refute response.resp_body =~ "credentials"
      assert get_resp_header(response, "cache-control") == ["private, no-store"]
    end
  end

  test "detail includes original documents and source dates, not invented case status", %{
    conn: conn,
    client: client
  } do
    notice = notice!(client, "DETAIL")
    body = conn |> get(@base <> "/#{notice.id}") |> contract_response(200)
    assert body["notice"]["reply_due_on"] == "2026-09-30"

    assert body["notice"]["documents"] == [
             %{
               "name" => "Notice.pdf",
               "type" => "application/pdf",
               "url" => "/notices/#{notice.id}/documents/0"
             }
           ]

    refute Map.has_key?(body["notice"], "status")
  end

  test "foreign records and malformed ids are unavailable", %{conn: conn} do
    %{org: other} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: other.id,
        name: "Other",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    notice = notice!(client, "FOREIGN")
    assert conn |> get(@base <> "/#{notice.id}") |> contract_response(404)
    assert conn |> post(@base <> "/clients/#{client.id}/check", %{}) |> contract_response(404)

    assert conn
           |> post(@base <> "/clients/#{client.id}/otp", %{username: "x"})
           |> contract_response(404)

    assert conn |> get(@base <> "/999999999999999999999999999999") |> contract_response(404)
    assert conn |> get(@base <> "/oops") |> contract_response(404)
    assert (conn |> get(@base) |> contract_response(200))["notices"] == []
  end

  test "viewer may read but all writes require permission", %{conn: conn} do
    %{user: viewer} = user_with_org_fixture(%{role: "viewer"})
    conn = log_in_user(conn, viewer)
    body = conn |> get(@base) |> contract_response(200)
    refute body["permissions"]["check"]
    refute body["permissions"]["connect"]

    for path <- ["/check", "/retry", "/clients/1/check", "/clients/1/otp", "/clients/1/verify"] do
      assert conn |> post(@base <> path, %{}) |> contract_response(403)
    end

    assert build_conn() |> get(@base) |> contract_response(401)
  end

  test "failed connection checks never masquerade as checked and keep saved notices", %{
    conn: conn,
    client: client
  } do
    notice!(client, "SAVED")
    assert conn |> post(@base <> "/clients/#{client.id}/check", %{}) |> contract_response(409)
    body = conn |> post(@base <> "/check", %{}) |> contract_response(200)
    assert body["run"]["failed"] == 1
    assert body["run"]["checked"] == 0
    assert [%{"reference" => "SAVED", "new" => false}] = body["notices"]
    assert body["run"]["retry_count"] == 0
    assert conn |> post(@base <> "/retry", %{}) |> contract_response(200)
  end

  test "OTP connects the right client and checking queues separately", %{
    conn: conn,
    client: client,
    org: org
  } do
    Req.Test.expect(Whitebooks, fn request ->
      Req.Test.json(request, %{"status_cd" => "1", "txn" => "secret-transaction"})
    end)

    body =
      conn
      |> post(@base <> "/clients/#{client.id}/otp", %{username: "gst-user"})
      |> contract_response(200)

    token = body["challenge"]
    refute token =~ "secret-transaction"

    assert conn
           |> post(@base <> "/clients/#{client.id}/verify", %{challenge: "bad", otp: "123456"})
           |> contract_response(422)

    {:ok, other} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Same firm other client",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    assert conn
           |> post(@base <> "/clients/#{other.id}/verify", %{challenge: token, otp: "123456"})
           |> contract_response(422)

    Req.Test.expect(Whitebooks, fn request -> Req.Test.json(request, %{"status_cd" => "1"}) end)

    body =
      conn
      |> post(@base <> "/clients/#{client.id}/verify", %{challenge: token, otp: "123456"})
      |> contract_response(200)

    assert Enum.find(body["clients"], &(&1["id"] == client.id))["state"] == "not_checked"
    body = conn |> post(@base <> "/clients/#{client.id}/check", %{}) |> contract_response(200)
    assert body["checking"]
    assert Nila.Notices.checking?(org.id, client.id)
  end

  defp notice!(client, ref) do
    Repo.insert!(%Notice{
      client_id: client.id,
      gstin: client.gstin,
      reference: ref,
      notice_type: "REMINDER",
      issued_on: ~D[2026-09-01],
      reply_due_on: ~D[2026-09-30],
      fetched_at: DateTime.utc_now(),
      payload: %{
        "detail" => %{
          "maindocs" => [
            %{
              "dcupdtls" => %{"id" => "doc", "docName" => "Notice.pdf", "ct" => "application/pdf"}
            }
          ],
          "suppdocs" => []
        }
      }
    })
  end
end
