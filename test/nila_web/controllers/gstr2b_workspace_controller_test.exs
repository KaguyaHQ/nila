defmodule NilaWeb.Gstr2bWorkspaceControllerTest do
  import NilaWeb.ApiContract, only: [contract_response: 2]
  use NilaWeb.ConnCase, async: false
  import Ecto.Query
  alias Nila.Repo
  alias Nila.Gst.Portal.{Statement, Challenge}
  alias Nila.Integrations.Whitebooks

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Nila.Clients.create_client(%{
        org_id: org.id,
        name: "Portal API",
        gstin: "33AEWPH4158J1Z3",
        type: "company"
      })

    previous = Application.get_env(:nila, Whitebooks)

    Application.put_env(:nila, Whitebooks,
      client_id: "test",
      client_secret: "secret",
      email: "test@example.test",
      ip_address: "127.0.0.1",
      req_options: [plug: {Req.Test, Whitebooks}]
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:nila, Whitebooks, previous),
        else: Application.delete_env(:nila, Whitebooks)
    end)

    %{
      conn: log_in_user(conn, user),
      user: user,
      org: org,
      client: client,
      path: "/api/workspace/purchases/#{client.id}/2026-08/gstr2b"
    }
  end

  test "read has connection permissions and no side effects", c do
    response = get(c.conn, c.path)
    body = contract_response(response, 200)
    assert body["connection"]["state"] == "not_connected"
    assert body["permissions"]["connect"]
    assert body["statement"] == nil
    refute Map.has_key?(body["connection"], "credentials")
    refute Map.has_key?(body["connection"], "txn")
    refute body["fetching"]
    assert get_resp_header(response, "cache-control") == ["private, no-store"]
    assert Repo.aggregate(Statement, :count) == 0

    assert c.conn |> post(c.path <> "/fetch", %{}) |> contract_response(409) |> Map.get("code") ==
             "connection_required"
  end

  test "authentication tenant and role boundaries", c do
    assert build_conn() |> get(c.path) |> contract_response(401)
    %{org: other_org} = user_with_org_fixture()

    {:ok, other} =
      Nila.Clients.create_client(%{
        org_id: other_org.id,
        name: "Other",
        gstin: "33AEWPH4158J1Z3",
        type: "company"
      })

    assert c.conn
           |> get("/api/workspace/purchases/#{other.id}/2026-08/gstr2b")
           |> contract_response(404)

    Repo.update_all(from(m in Nila.Orgs.Membership, where: m.user_id == ^c.user.id),
      set: [role: "viewer"]
    )

    for action <- ["fetch", "otp", "verify", "import"] do
      assert c.conn
             |> post(c.path <> "/" <> action, %{username: "user", otp: "123456", challenge: "bad"})
             |> contract_response(403)
    end
  end

  test "encrypted OTP challenge binds user client and month and verifies then queues", c do
    Req.Test.expect(Whitebooks, fn conn ->
      assert conn.request_path == "/authentication/otprequest"

      Req.Test.json(conn, %{
        "status_cd" => "1",
        "txn" => "private-provider-transaction"
      })
    end)

    body = c.conn |> post(c.path <> "/otp", %{username: "portaluser"}) |> contract_response(200)
    refute body["challenge"] =~ "private-provider-transaction"
    assert body["expires_in"] == 900
    wrong_month = String.replace(c.path, "2026-08", "2026-09")

    assert c.conn
           |> post(wrong_month <> "/verify", %{challenge: body["challenge"], otp: "123456"})
           |> contract_response(422)

    Req.Test.expect(Whitebooks, fn conn ->
      assert conn.request_path == "/authentication/authtoken"
      Req.Test.json(conn, %{"status_cd" => "1", "data" => %{}})
    end)

    result =
      c.conn
      |> post(c.path <> "/verify", %{challenge: body["challenge"], otp: "123456"})
      |> contract_response(202)

    assert result["fetching"]
    assert result["connection"]["state"] == "connected"
    assert result["statement"]["status"] == "pending"
  end

  test "invalid expired and wrong-user challenges cannot authenticate", c do
    challenge = %Challenge{
      client_id: c.client.id,
      org_id: c.org.id,
      requested_at: DateTime.add(DateTime.utc_now(), -901),
      account: %{gstin: c.client.gstin, username: "user", txn: "secret", ip_address: "127.0.0.1"}
    }

    payload = %{
      user_id: c.user.id,
      org_id: c.org.id,
      client_id: c.client.id,
      period: "2026-08",
      challenge: challenge
    }

    tokens = [
      "bad",
      Phoenix.Token.encrypt(NilaWeb.Endpoint, "gstr2b-workspace-otp-v1", payload),
      Phoenix.Token.encrypt(NilaWeb.Endpoint, "gstr2b-workspace-otp-v1", %{
        payload
        | user_id: c.user.id + 1
      })
    ]

    tokens =
      tokens ++
        [
          Phoenix.Token.encrypt(NilaWeb.Endpoint, "gstr2b-workspace-otp-v1", payload,
            signed_at: System.system_time(:second) - 1000
          ),
          Phoenix.Token.encrypt(NilaWeb.Endpoint, "gstr2b-workspace-otp-v1", %{
            payload
            | client_id: c.client.id + 1
          })
        ]

    for token <- tokens do
      assert c.conn
             |> post(c.path <> "/verify", %{challenge: token, otp: "123456"})
             |> contract_response(422)
    end

    assert Repo.aggregate(Nila.Gst.Portal.Connection, :count) == 0
  end

  test "failed refresh retains saved source and exposes retry without altering it", c do
    document = %{"data" => %{"gstin" => c.client.gstin, "rtnprd" => "082026", "docdata" => %{}}}

    saved =
      Repo.insert!(%Statement{
        client_id: c.client.id,
        gstin: c.client.gstin,
        period: "2026-08",
        document: document,
        fetched_at: DateTime.utc_now(),
        status: "failed",
        last_error: "Not available",
        failure_reason: "statement_unavailable"
      })

    body = c.conn |> get(c.path) |> contract_response(200)
    assert body["statement"]["last_error"] == "Not available"
    assert body["statement"]["download_url"] =~ Integer.to_string(saved.id)
    assert body["import"]["needed"]
    assert Repo.get!(Statement, saved.id).document == document
    assert c.conn |> post(c.path <> "/import", %{}) |> contract_response(202)
  end

  test "signed-off month refuses preparation without changing its source", c do
    month =
      Repo.insert!(%Nila.Gst.Purchase.Month{
        org_id: c.org.id,
        client_id: c.client.id,
        period: "2026-08"
      })

    Repo.insert!(%Nila.Gst.Filing.Signoff{
      org_id: c.org.id,
      client_month_id: month.id,
      signed_by_id: c.user.id,
      snapshot: %{}
    })

    body = c.conn |> post(c.path <> "/import", %{}) |> contract_response(422)
    assert body["error"] =~ "signed off"
    refute Repo.exists?(from d in Nila.Gst.Intake.Dump, where: d.client_id == ^c.client.id)
  end
end
