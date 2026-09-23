defmodule NilaWeb.Gst.MonthLiveWorkpaperTest do
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Nila.GstFixtures

  alias Nila.Clients
  alias Nila.Gst.Purchase.Months, as: PurchaseMonths

  @period "2025-10"

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Breeze Tech",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    work_dump!(org, client, @period, "sales", "%PDF-1.4 fake bytes", user.id)
    gstr2b_arrived!(org, client, @period)

    {:ok, _purchase} =
      PurchaseMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "worked",
        register_rows: [],
        recon: %{},
        summary: %{}
      })

    %{conn: log_in_user(conn, user), client: client}
  end

  test "the direct GSTR-3B route links to sales and purchases", %{conn: conn, client: client} do
    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}/gstr3b")

    assert has_element?(view, "#gstr3b-open-sales[href='/gst/#{client.id}/#{@period}/sales']")

    assert has_element?(
             view,
             "#gstr3b-open-purchases-header[href='/gst/#{client.id}/#{@period}/purchases']"
           )

    refute has_element?(view, "#month-workpaper-tab-purchases")
    refute has_element?(view, "#month-workpaper-tab-gstr3b")
  end

  test "a bare month URL enters sales and purchase workflow has its own route", %{
    conn: conn,
    client: client
  } do
    assert {:error, {:live_redirect, %{to: target}}} =
             live(conn, "/gst/#{client.id}/#{@period}")

    assert target == "/gst/#{client.id}/#{@period}/sales"

    assert conn |> get("/gst/#{client.id}/#{@period}/purchases") |> redirected_to() ==
             "/app/gst/#{client.id}/#{@period}/purchases"
  end
end
