defmodule NilaWeb.Gstr1MonthLiveTest do
  use NilaWeb.ConnCase
  use Oban.Testing, repo: Nila.Repo

  import Phoenix.LiveViewTest

  alias Nila.Clients
  alias Nila.Gst.Gstr1Worker
  alias Nila.Storage

  @period "2026-05"

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Breeze Tech",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    pdf_key = "gstr1/#{org.id}/#{client.id}/#{@period}/source/bills.pdf"
    {:ok, _} = Storage.put(pdf_key, "%PDF-1.4 fake bytes")

    :ok =
      perform_job(Gstr1Worker, %{
        "org_id" => org.id,
        "client_id" => client.id,
        "period" => @period,
        "pdf_key" => pdf_key
      })

    %{conn: log_in_user(conn, user), org: org, client: client}
  end

  test "renders the worked sales month with issue flags", %{conn: conn, client: client} do
    {:ok, view, _html} = live(conn, ~p"/gstr1/#{client.id}/#{@period}")

    assert has_element?(view, "#gstr1-month-page")
    assert has_element?(view, "#gstr1-inv-20\\/2026-27")
    assert render(view) =~ "validation issues"
  end

  test "clicking an invoice shows its issues in the evidence modal", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gstr1/#{client.id}/#{@period}")

    view |> element("#gstr1-inv-20\\/2026-27") |> render_click()

    assert has_element?(view, "#gstr1-evidence-modal")
    assert render(view) =~ "Grand Total Mismatch"
  end

  test "downloads the portal-shaped GSTR-1 JSON", %{conn: conn, client: client} do
    conn = get(conn, ~p"/gstr1/#{client.id}/#{@period}/return.json")

    assert response_content_type(conn, :json)
    body = json_response(conn, 200)
    assert body["gstin"] == "33AEWPH4158J1Z3"
    assert body["fp"] == "052026"
    assert is_list(body["b2b"])
  end

  test "another org cannot open the month or fetch the JSON", %{client: client} do
    %{user: other_user} = user_with_org_fixture()
    conn = log_in_user(build_conn(), other_user)

    assert {:error, {:live_redirect, %{to: "/today"}}} =
             live(conn, ~p"/gstr1/#{client.id}/#{@period}")

    conn =
      get(build_conn() |> log_in_user(other_user), ~p"/gstr1/#{client.id}/#{@period}/return.json")

    assert response(conn, 404)
  end
end
