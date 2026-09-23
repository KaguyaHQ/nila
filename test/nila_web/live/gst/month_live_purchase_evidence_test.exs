defmodule NilaWeb.Gst.MonthLivePurchaseEvidenceTest do
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Nila.AccountsFixtures

  alias Nila.Clients

  alias Nila.Gst.Purchase.Months
  alias Nila.Storage

  @period "2025-10"

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{org_id: org.id, name: "Breeze Tech", type: "company"})

    {:ok, _month} =
      Months.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "worked",
        register_rows: [],
        recon: %{},
        summary: %{}
      })

    %{conn: log_in_user(conn, user), user: user, org: org, client: client}
  end

  test "the owning org can fetch an evidence image", %{
    conn: conn,
    org: org,
    client: client
  } do
    key = Months.evidence_key(org.id, client.id, @period, "page_09.png")
    {:ok, _} = Storage.put(key, "evidence-image")

    conn = get(conn, ~p"/gst/#{client.id}/#{@period}/evidence/page_09.png")

    assert response(conn, 200) == "evidence-image"
    assert get_resp_header(conn, "content-type") |> hd() =~ "image/png"
  end

  test "logged-out visitors cannot fetch evidence", %{client: client} do
    conn =
      get(Phoenix.ConnTest.build_conn(), ~p"/gst/#{client.id}/#{@period}/evidence/page_09.png")

    assert redirected_to(conn) == "/users/log_in"
  end

  test "another org cannot fetch this org's evidence image", %{client: client} do
    %{user: other_user} = user_with_org_fixture(%{org: %{gstin: "27AAPFU0939F1ZV"}})
    conn = log_in_user(Phoenix.ConnTest.build_conn(), other_user)

    conn = get(conn, ~p"/gst/#{client.id}/#{@period}/evidence/page_09.png")

    assert response(conn, 404)
  end

  test "evidence rejects a basename outside the image whitelist", %{
    conn: conn,
    client: client
  } do
    conn = get(conn, ~p"/gst/#{client.id}/#{@period}/evidence/#{"secret.txt"}")

    assert response(conn, 404)
  end

end
