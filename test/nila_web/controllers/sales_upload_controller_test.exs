defmodule NilaWeb.SalesUploadControllerTest do
  use NilaWeb.ConnCase, async: true
  import Ecto.Query

  alias Nila.{Clients, Repo, Storage}
  alias Nila.Gst.Intake.{Dump, Dumps}
  alias Nila.Gst.Sales.Batch

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "PDF client",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    %{
      conn: log_in_user(conn, user),
      user: user,
      org: org,
      client: client,
      path: "/api/workspace/sales/#{client.id}/2026-06/uploads"
    }
  end

  test "verified PDFs create one attributed batch and retrying the token is idempotent",
       context do
    %{conn: conn, path: path, org: org, client: client, user: user} = context
    bytes = "%PDF-1.4\nSales bill\n%%EOF"

    prepared =
      conn
      |> post(path <> "/prepare", %{
        files: [
          %{name: "bill.pdf", size: byte_size(bytes)},
          %{name: "bill.pdf", size: byte_size(bytes)}
        ]
      })
      |> json_response(200)

    for file <- prepared["files"], do: put_file(file, bytes)

    assert conn |> post(path, %{token: prepared["token"]}) |> json_response(200) == %{
             "ok" => true
           }

    assert conn |> post(path, %{token: prepared["token"]}) |> json_response(200) == %{
             "ok" => true
           }

    {:ok, payload} =
      Phoenix.Token.verify(NilaWeb.Endpoint, "sales PDF upload", prepared["token"], max_age: 3600)

    expired =
      Phoenix.Token.sign(NilaWeb.Endpoint, "sales PDF upload", payload,
        signed_at: System.system_time(:second) - 7200
      )

    assert conn |> post(path, %{token: expired}) |> json_response(200) == %{"ok" => true}
    dumps = Dumps.list(org.id, client.id, "2026-06")
    assert length(dumps) == 2
    assert length(Enum.uniq_by(dumps, & &1.sales_batch_id)) == 1

    for dump <- dumps do
      assert dump.brought_in_by_id == user.id
      assert dump.status == "received"
      assert dump.meta["original_name"] == "bill.pdf"
      assert {:ok, ^bytes} = Storage.get(hd(dump.file_keys))

      assert Repo.exists?(
               from j in Oban.Job,
                 where:
                   j.worker == "Nila.Gst.Intake.DumpWorker" and
                     fragment("?->>'dump_id'", j.args) == ^to_string(dump.id)
             )

      on_exit(fn -> Storage.delete(hd(dump.file_keys)) end)
    end

    # Reusing a still-valid PUT URL cannot change the queued source.
    put_file(hd(prepared["files"]), "%PDF-overwritten")
    assert {:ok, ^bytes} = Storage.get(hd(hd(dumps).file_keys))
    body = conn |> get(path) |> json_response(200)
    assert body["processing"]
    assert [%{"files" => [_, _], "review_url" => url}] = body["batches"]
    assert url == "/sales-bills/#{client.id}/batch/#{Batch.ref(dumps)}"
  end

  test "invalid PDF bytes and mismatched lengths create no dumps or batches", %{
    conn: conn,
    path: path,
    client: client
  } do
    for {bytes, expected_size} <- [{"not PDF", 7}, {"%PDF-short", 99}] do
      prepared =
        conn
        |> post(path <> "/prepare", %{files: [%{name: "bill.pdf", size: expected_size}]})
        |> json_response(200)

      put_file(hd(prepared["files"]), bytes)
      assert conn |> post(path, %{token: prepared["token"]}) |> json_response(422)
    end

    refute Repo.exists?(from d in Dump, where: d.client_id == ^client.id)
    refute Repo.exists?(from b in Batch, where: b.client_id == ^client.id)
  end

  test "valid first file is rolled back when another file has not arrived", %{
    conn: conn,
    path: path,
    client: client
  } do
    bytes = "%PDF-test"

    prepared =
      conn
      |> post(path <> "/prepare", %{
        files: [
          %{name: "one.pdf", size: byte_size(bytes)},
          %{name: "two.pdf", size: byte_size(bytes)}
        ]
      })
      |> json_response(200)

    put_file(hd(prepared["files"]), bytes)
    assert conn |> post(path, %{token: prepared["token"]}) |> json_response(422)
    refute Repo.exists?(from d in Dump, where: d.client_id == ^client.id)
  end

  test "selection validates count, names, sizes, and PDF extension", %{conn: conn, path: path} do
    for files <- [
          [],
          List.duplicate(%{name: "bill.pdf", size: 1}, 51),
          [%{name: "bill.xlsx", size: 1}],
          [%{name: "bill.pdf", size: 0}],
          [%{name: "bill.pdf", size: 50_000_001}],
          [%{name: "../bill.pdf", size: 1}],
          [%{name: "bill.pdf", size: "2"}]
        ] do
      assert conn |> post(path <> "/prepare", %{files: files}) |> json_response(422)
    end
  end

  test "token is bound to month, client, user and expiry", %{conn: conn, path: path, org: org} do
    prepared =
      conn
      |> post(path <> "/prepare", %{files: [%{name: "bill.pdf", size: 9}]})
      |> json_response(200)

    token = prepared["token"]

    assert conn
           |> post(String.replace(path, "2026-06", "2026-07"), %{token: token})
           |> json_response(422)

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Other client",
        type: "company"
      })

    assert conn
           |> post("/api/workspace/sales/#{client.id}/2026-06/uploads", %{token: token})
           |> json_response(422)

    {:ok, payload} =
      Phoenix.Token.verify(NilaWeb.Endpoint, "sales PDF upload", token, max_age: 3600)

    wrong_user =
      Phoenix.Token.sign(NilaWeb.Endpoint, "sales PDF upload", %{
        payload
        | user_id: payload.user_id + 1
      })

    expired =
      Phoenix.Token.sign(NilaWeb.Endpoint, "sales PDF upload", payload,
        signed_at: System.system_time(:second) - 7200
      )

    for invalid <- [wrong_user, expired, token <> "bad", nil] do
      assert conn |> post(path, %{token: invalid}) |> json_response(422)
      assert conn |> post(path <> "/prepare", %{token: invalid}) |> json_response(422)
    end
  end

  test "refresh renews PUT access to the same files without changing the batch token", %{
    conn: conn,
    path: path
  } do
    prepared =
      conn
      |> post(path <> "/prepare", %{files: [%{name: "bill.pdf", size: 9}]})
      |> json_response(200)

    refreshed =
      conn |> post(path <> "/prepare", %{token: prepared["token"]}) |> json_response(200)

    assert refreshed["token"] == prepared["token"]
    assert hd(refreshed["files"])["name"] == "bill.pdf"
    assert upload_key(hd(refreshed["files"])) == upload_key(hd(prepared["files"]))
    put_file(hd(refreshed["files"]), "%PDF-test")

    assert conn |> post(path, %{token: prepared["token"]}) |> json_response(200) == %{
             "ok" => true
           }
  end

  test "history preserves failed and partial states without leaking internal errors", %{
    conn: conn,
    path: path,
    org: org,
    client: client
  } do
    {:ok, failed} =
      Dumps.record(%{org_id: org.id, client_id: client.id}, %{
        period: "2026-06",
        kind: "sales",
        status: "failed",
        error: "secret provider error",
        meta: %{"original_name" => "failed.pdf"}
      })

    {:ok, _} =
      Dumps.record(%{org_id: org.id, client_id: client.id}, %{
        period: "2026-06",
        kind: "sales",
        status: "extracted",
        meta: %{"unaccounted_pages" => [2]}
      })

    {:ok, _} =
      Dumps.record(%{org_id: org.id, client_id: client.id}, %{period: "2026-06", kind: "purchase"})

    body = conn |> get(path) |> json_response(200)
    assert length(body["batches"]) == 2
    refute body["processing"]
    files = Enum.flat_map(body["batches"], & &1["files"])
    assert Enum.find(files, &(&1["id"] == failed.id))["error"] != "secret provider error"
    assert Enum.any?(files, &(&1["label"] == "Partly read"))
  end

  test "signed out, other firms, and invalid periods are rejected", %{conn: conn, path: path} do
    assert build_conn() |> get(path) |> json_response(401)
    %{user: other} = user_with_org_fixture()
    assert build_conn() |> log_in_user(other) |> get(path) |> json_response(404)
    assert conn |> get(String.replace(path, "2026-06", "2026-13")) |> json_response(400)
  end

  test "viewers can read history but cannot prepare, refresh, or commit", %{
    conn: conn,
    path: path,
    user: user,
    org: org
  } do
    Repo.update_all(
      from(m in Nila.Orgs.Membership, where: m.org_id == ^org.id and m.user_id == ^user.id),
      set: [role: "viewer"]
    )

    assert conn |> get(path) |> json_response(200)

    assert conn
           |> post(path <> "/prepare", %{files: [%{name: "bill.pdf", size: 9}]})
           |> json_response(403)

    assert conn |> post(path <> "/prepare", %{token: "anything"}) |> json_response(403)
    assert conn |> post(path, %{token: "anything"}) |> json_response(403)
  end

  defp put_file(file, bytes) do
    key = upload_key(file)
    {:ok, _} = Storage.put(key, bytes, content_type: "application/pdf")
    on_exit(fn -> Storage.delete(key) end)
  end

  defp upload_key(file) do
    token =
      file["url"]
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("token")

    {:ok, key} = Storage.Local.verify_upload_token(token)
    key
  end
end
