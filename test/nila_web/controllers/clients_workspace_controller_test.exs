defmodule NilaWeb.ClientsWorkspaceControllerTest do
  use NilaWeb.ConnCase, async: true
  import Ecto.Query
  alias Nila.{Clients, Repo}

  @base "/api/workspace/clients"

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Original client",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    %{conn: log_in_user(conn, user), user: user, org: org, client: client}
  end

  test "directory and detail contain only the current firm's clients", %{
    conn: conn,
    org: org,
    client: client
  } do
    %{org: other} = user_with_org_fixture()

    {:ok, _} =
      Clients.create_client(%{org_id: other.id, name: "Other firm client", type: "company"})

    response = get(conn, @base <> "?period=2026-06")
    body = json_response(response, 200)

    assert body["clients"] == [
             %{
               "id" => client.id,
               "name" => client.name,
               "gstin" => client.gstin,
               "sales_path" => "/gst/#{client.id}/2026-06/sales"
             }
           ]

    assert body["user"]["org"] == org.name
    assert body["can_edit"]
    assert body["period"] == "2026-06"
    assert get_resp_header(response, "cache-control") == ["private, no-store"]

    assert conn |> get(@base <> "/#{client.id}") |> json_response(200) == %{
             "client" => %{"id" => client.id, "name" => client.name, "gstin" => client.gstin},
             "can_edit" => true
           }
  end

  test "create and update allow only name and GSTIN and return field errors", %{
    conn: conn,
    org: org,
    client: client
  } do
    created =
      conn
      |> post(@base, %{
        client: %{
          name: "New client",
          gstin: "",
          org_id: -1,
          type: "individual",
          chase_channel: "email",
          gst_username: "injected"
        }
      })
      |> json_response(200)

    {:ok, saved} = Clients.get_client(org.id, created["client"]["id"])
    assert saved.type == "company"
    assert saved.chase_channel == "none"
    assert saved.gstin == nil
    assert saved.gst_username == nil

    changed =
      conn
      |> patch(@base <> "/#{client.id}", %{
        client: %{name: "Renamed", gstin: "33aewph4158j1z3", org_id: -1, type: "individual"}
      })
      |> json_response(200)

    assert changed["client"]["name"] == "Renamed"
    assert changed["client"]["gstin"] == client.gstin
    {:ok, saved} = Clients.get_client(org.id, client.id)
    assert saved.type == "company"
    invalid = conn |> post(@base, %{client: %{name: "", gstin: "bad"}}) |> json_response(422)
    assert invalid["errors"]["name"] != []
    assert invalid["errors"]["gstin"] != []
    assert conn |> post(@base, %{client: %{name: "New client"}}) |> json_response(422)

    assert conn
           |> post(@base, %{client: %{name: String.duplicate("x", 256)}})
           |> json_response(422)
  end

  test "tenant, login, role and malformed identifiers are enforced", %{
    conn: conn,
    client: client,
    org: org,
    user: user
  } do
    assert build_conn() |> get(@base) |> json_response(401)
    %{user: other} = user_with_org_fixture()
    outsider = build_conn() |> log_in_user(other)
    assert outsider |> get(@base <> "/#{client.id}") |> json_response(404)

    assert outsider
           |> patch(@base <> "/#{client.id}", %{client: %{name: "Stolen"}})
           |> json_response(404)

    assert conn |> get(@base <> "/bad") |> json_response(400)
    assert conn |> get(@base <> "?period=2026-13") |> json_response(400)

    Repo.update_all(
      from(m in Nila.Orgs.Membership, where: m.user_id == ^user.id and m.org_id == ^org.id),
      set: [role: "viewer"]
    )

    refute (conn |> get(@base) |> json_response(200))["can_edit"]
    assert conn |> post(@base, %{client: %{name: "No"}}) |> json_response(403)
    assert conn |> patch(@base <> "/#{client.id}", %{client: %{name: "No"}}) |> json_response(403)
    assert conn |> post(@base <> "/import/preview", %{}) |> json_response(403)
    assert conn |> post(@base <> "/import", %{token: "anything"}) |> json_response(403)
  end

  test "Excel preview writes nothing, retains username, and import retry skips duplicates", %{
    conn: conn,
    org: org
  } do
    upload =
      workbook([
        ["Added from workbook", "", ""],
        ["Existing GSTIN", "33AEWPH4158J1Z3", "portal-user"],
        ["Broken", "bad", ""]
      ])

    preview = conn |> post(@base <> "/import/preview", %{file: upload}) |> json_response(200)
    assert preview["ready_count"] == 1
    assert Enum.map(preview["rows"], & &1["status"]) == ["ready", "skip", "invalid"]
    assert Enum.at(preview["rows"], 1)["gst_username"] == "portal-user"
    assert length(Clients.list_clients(org.id)) == 1

    saved =
      conn
      |> post(@base <> "/import", %{
        token: preview["token"],
        rows: [%{name: "Injected", status: "ready"}],
        org_id: -1
      })
      |> json_response(200)

    assert saved["added_count"] == 1
    assert saved["skipped_count"] == 1
    assert saved["invalid_count"] == 1
    retried = conn |> post(@base <> "/import", %{token: preview["token"]}) |> json_response(200)
    assert retried["added_count"] == 0
    assert retried["skipped_count"] == 2

    assert Enum.map(Clients.list_clients(org.id), & &1.name) == [
             "Added from workbook",
             "Original client"
           ]
  end

  test "import tickets reject tampering, expiry, another user and firm", %{conn: conn} do
    upload = workbook([["Import client", "", ""]])
    preview = conn |> post(@base <> "/import/preview", %{file: upload}) |> json_response(200)

    {:ok, payload} =
      Phoenix.Token.verify(NilaWeb.Endpoint, "clients workspace import", preview["token"],
        max_age: 3600
      )

    expired =
      Phoenix.Token.sign(NilaWeb.Endpoint, "clients workspace import", payload,
        signed_at: System.system_time(:second) - 7200
      )

    wrong_user =
      Phoenix.Token.sign(NilaWeb.Endpoint, "clients workspace import", %{
        payload
        | user_id: payload.user_id + 1
      })

    for token <- [preview["token"] <> "bad", expired, wrong_user, nil] do
      assert conn |> post(@base <> "/import", %{token: token}) |> json_response(422)
    end

    %{user: other} = user_with_org_fixture()

    assert build_conn()
           |> log_in_user(other)
           |> post(@base <> "/import", %{token: preview["token"]})
           |> json_response(422)
  end

  test "preview rejects missing and invalid workbooks", %{conn: conn} do
    assert conn |> post(@base <> "/import/preview", %{}) |> json_response(422)
    path = Path.join(System.tmp_dir!(), "clients-bad-#{Ecto.UUID.generate()}.xlsx")
    File.write!(path, "not an Excel workbook")
    on_exit(fn -> File.rm(path) end)

    assert conn
           |> post(@base <> "/import/preview", %{
             file: %Plug.Upload{path: path, filename: "bad.xlsx"}
           })
           |> json_response(422)
  end

  defp workbook(rows) do
    sheet =
      Enum.with_index([["Client name", "GSTIN", "GST username"] | rows])
      |> Enum.reduce(XlsxWriter.new_sheet("Clients"), fn {cells, row}, sheet ->
        Enum.with_index(cells)
        |> Enum.reduce(sheet, fn {value, col}, acc -> XlsxWriter.write(acc, row, col, value) end)
      end)

    {:ok, bytes} = XlsxWriter.generate([sheet])
    path = Path.join(System.tmp_dir!(), "clients-import-#{Ecto.UUID.generate()}.xlsx")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)

    %Plug.Upload{
      path: path,
      filename: "clients.xlsx",
      content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    }
  end
end
