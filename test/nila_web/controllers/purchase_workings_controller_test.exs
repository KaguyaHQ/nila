defmodule NilaWeb.PurchaseWorkingsControllerTest do
  use NilaWeb.ConnCase, async: true
  alias Nila.Gst.Purchase.Months

  test "downloads the authorized month's working and hides another firm's month", %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Nila.Clients.create_client(%{
        org_id: org.id,
        name: "Purchase client",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    {:ok, _} =
      Months.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: "2026-08",
        state: "worked",
        recon: %{},
        register_rows: [],
        summary: %{}
      })

    path = "/gst/#{client.id}/2026-08/purchases/workings.xlsx"
    downloaded = conn |> log_in_user(user) |> get(path)
    assert response(downloaded, 200) =~ "PK"
    assert get_resp_header(downloaded, "content-disposition") |> hd() =~ "purchase_working_"
    %{user: other} = user_with_org_fixture()
    assert conn |> recycle() |> log_in_user(other) |> get(path) |> response(404)
  end

  test "requires export permission", %{conn: conn} do
    assert conn
           |> assign(:current_scope, %Nila.Accounts.Scope{})
           |> NilaWeb.PurchaseWorkingsController.download(%{
             "client_id" => "1",
             "period" => "2026-08"
           })
           |> response(403)
  end

  test "exports the recorded snapshot amounts rather than a newly computed position", %{
    conn: conn
  } do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Nila.Clients.create_client(%{
        org_id: org.id,
        name: "Signed client",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    {:ok, month} =
      Months.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: "2026-08",
        state: "worked",
        recon: %{},
        register_rows: [],
        summary: %{}
      })

    workings = Nila.Gst.Purchase.Resolutions.workings(month)

    snapshot = %{
      "rows" => [],
      "summary" => workings.summary,
      "gstr3b" => workings.gstr3b,
      "itc" => Map.put(workings.itc, "claimable_paise", 987_654),
      "case_lines" => [],
      "review" => %{
        "recon" => %{},
        "baseline" => %{},
        "decisions" => %{},
        "accepted_reasons" => %{},
        "gstr2b_decisions" => %{}
      }
    }

    Nila.Repo.insert!(%Nila.Gst.Filing.Signoff{
      org_id: org.id,
      client_month_id: month.id,
      signed_by_id: user.id,
      snapshot: snapshot
    })

    bytes =
      conn
      |> log_in_user(user)
      |> get("/gst/#{client.id}/2026-08/purchases/workings.xlsx")
      |> response(200)

    {:ok, files} = :zip.unzip(bytes, [:memory])
    files = Map.new(files, fn {path, data} -> {to_string(path), data} end)
    assert files["xl/sharedStrings.xml"] =~ "Recorded sign-off snapshot"
    assert files["xl/worksheets/sheet1.xml"] =~ "<v>9876.54</v>"
  end
end
