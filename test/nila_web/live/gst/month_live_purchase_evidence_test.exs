defmodule NilaWeb.Gst.MonthLivePurchaseEvidenceTest do
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Nila.AccountsFixtures

  alias Nila.Clients
  alias Nila.Gst.Filing.Calendar
  alias Nila.Gst.Intake.Dumps
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

  test "a dump after filing points to the open month and cannot be released", %{
    conn: conn,
    user: user,
    org: org,
    client: client
  } do
    {:ok, dump} =
      Dumps.record(
        %{org_id: org.id, client_id: client.id, brought_in_by_id: user.id},
        %{period: @period, kind: "purchase", file_keys: ["late/purchase.pdf"]}
      )

    dump = Dumps.mark_after_filing(dump)
    open_period = Calendar.closeable_period(Date.utc_today())

    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}/gstr3b")

    assert has_element?(view, "#month-headline", "Documents arrived after this month was filed")

    assert has_element?(
             view,
             "#month-door-after-filing[href='/gst/upload?client_id=#{client.id}&period=#{open_period}']"
           )

    assert doors(view) == ["month-door-after-filing"]

    assert has_element?(
             view,
             "#month-purchase-sources #month-dump-#{dump.id}",
             "Added after filing"
           )

    assert has_element?(view, "#month-dump-#{dump.id}", "Move it to an open month")
    refute has_element?(view, "#month-dump-release-#{dump.id}")
    refute has_element?(view, "#month-dump-#{dump.id}", "reopen")
  end

  test "redirects logged-out visitors to log in", %{client: client} do
    assert {:error, {:redirect, %{to: "/users/log_in"}}} =
             live(Phoenix.ConnTest.build_conn(), "/gst/#{client.id}/#{@period}/gstr3b")
  end

  defp doors(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[id^='month-door-']")
    |> LazyHTML.attribute("id")
  end
end
