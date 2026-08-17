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

  test "the bare month selects sales and patches between one complete workpaper at a time", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    assert has_element?(view, "#month-workpaper-tab-sales[aria-current='page']")
    assert has_element?(view, "#month-sales")
    refute has_element?(view, "#month-register")
    refute has_element?(view, "#month-gstr3b-workpaper")

    view |> element("#month-workpaper-tab-purchases") |> render_click()
    assert_patch(view, "/gst/#{client.id}/#{@period}?track=purchases")
    assert has_element?(view, "#month-workpaper-tab-purchases[aria-current='page']")
    assert has_element?(view, "#month-register")
    refute has_element?(view, "#month-sales")
    refute has_element?(view, "#month-gstr3b-workpaper")

    view |> element("#month-workpaper-tab-gstr3b") |> render_click()
    assert_patch(view, "/gst/#{client.id}/#{@period}?track=gstr3b")
    assert has_element?(view, "#month-workpaper-tab-gstr3b[aria-current='page']")
    assert has_element?(view, "#month-gstr3b-workpaper")
    refute has_element?(view, "#month-sales")
    refute has_element?(view, "#month-register")
  end

  test "direct track URLs survive refresh and an invalid track canonicalizes to sales", %{
    conn: conn,
    client: client
  } do
    {:ok, purchases, _html} =
      live(conn, "/gst/#{client.id}/#{@period}?track=purchases")

    assert has_element?(purchases, "#month-workpaper-tab-purchases[aria-current='page']")
    assert has_element?(purchases, "#month-register")

    assert {:error, {:live_redirect, %{to: target}}} =
             live(conn, "/gst/#{client.id}/#{@period}?track=unknown")

    assert target == "/gst/#{client.id}/#{@period}?track=sales"
  end

  test "all workpapers remain available when their source data is absent", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")

    for track <- ~w(sales purchases gstr3b) do
      assert has_element?(view, "#month-workpaper-tab-#{track}")
    end
  end
end
