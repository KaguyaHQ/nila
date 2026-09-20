defmodule NilaWeb.Gst.MonthLivePurchaseCompactTest do
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Nila.GstFixtures

  alias Nila.Clients
  alias Nila.Gst.Filing.Signoffs
  alias Nila.Gst.Purchase.Months, as: ClientMonths
  alias Nila.Gst.Purchase.{Register, Resolutions}
  alias Nila.Gst.Sales.Months, as: SalesMonths

  @dir "tmp/register/breeze-2025-10"
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

    gstr2b_arrived!(org, client, @period)
    rows = read_fixture_json("register_rows.json")

    {:ok, _month} =
      ClientMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "worked",
        register_rows: rows,
        recon: read_fixture_json("recon.json"),
        summary: Register.summary(rows)
      })

    {:ok, client_month} = ClientMonths.get_by_period(org.id, client.id, @period)

    %{
      conn: log_in_user(conn, user),
      client: client,
      org: org,
      user: user,
      client_month: client_month
    }
  end

  test "the direct GSTR-3B workpaper keeps the return position and source records visible", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}/gstr3b")

    assert has_element?(view, "#month-3b", "Proposed GSTR-3B")
    assert has_element?(view, "#month-purchase-sources")
    assert has_element?(view, "#gstr3b-controls")
    assert has_element?(view, "#gstr3b-source-references")
    assert has_element?(view, "#gstr3b-open-sales")
    assert has_element?(view, "#gstr3b-open-purchases-header")
  end

  test "GSTR-3B exposes the current blocker and source actions", %{conn: conn, client: client} do
    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}/gstr3b")

    assert has_element?(view, "#gstr3b-primary-blocker")
    assert has_element?(view, "#gstr3b-primary-action")
    assert has_element?(view, "#month-purchase-sources")
    refute has_element?(view, "#month-workpaper-tab-purchases")
    refute has_element?(view, "#purchase-reconciliation-filters")
  end

  test "the current purchase workflow remains available from the GSTR-3B handoff", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}/gstr3b")

    assert has_element?(
             view,
             "#gstr3b-open-purchases-header[href='/gst/#{client.id}/#{@period}/purchases']"
           )
  end

  test "a provisional 3B uses Nila's current treatment", %{
    conn: conn,
    client: client,
    client_month: client_month
  } do
    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}/gstr3b")
    workings = Resolutions.workings(client_month)

    refute has_element?(view, "#gstr3b-itc-position")
    assert has_element?(view, "#month-3b", "Proposed GSTR-3B")
    assert has_element?(view, "#gstr3b-preview-status", "Provisional")
    assert has_element?(view, "#gst-3b-cash-pending", "Pending")

    assert has_element?(
             view,
             "#gst-3b-current-itc",
             Nila.Formatters.format_money_with_paise(workings.itc["claimable_paise"])
           )

    assert has_element?(view, "#gstr3b-primary-blocker", "Review decisions")
  end

  test "missing sales liability stays pending inside the provisional 3B", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}/gstr3b")

    assert render(view) =~ "Sales bills not in, so the GSTR-1 waits."
    assert has_element?(view, "#gst-3b-position", "Pending GSTR-1")
    assert has_element?(view, "#gst-3b-cash-pending", "Pending outward tax")
  end

  test "a signed month renders from its frozen snapshot", %{
    conn: conn,
    client: client,
    user: user,
    client_month: client_month
  } do
    scope = Nila.Accounts.Scope.for_user(user)
    month = settle_register!(client_month, user.id)

    month =
      choose_itc_treatment!(month, scope, %{
        "choice" => "later",
        "later_reason" => "review_pending"
      })

    {:ok, _} = Signoffs.sign_off(month, scope)
    {:ok, signoff} = Signoffs.latest_signoff(month.id)

    frozen =
      put_in(signoff.snapshot, ["gstr3b", "itc", "net_itc_4c"], %{
        "cgst" => 123_456,
        "sgst" => 0,
        "igst" => 0,
        "cess" => 0
      })

    signoff |> Ecto.Changeset.change(snapshot: frozen) |> Nila.Repo.update!()

    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}/gstr3b")

    assert has_element?(view, "#month-exit-gstr3b", "Signed by")
    assert has_element?(view, "#gstr3b-source-references", "Frozen at GSTR-3B sign-off")

    assert has_element?(
             view,
             "#gst-3b-current-itc",
             Nila.Formatters.format_money_with_paise(123_456)
           )

    refute has_element?(view, "#month-workpaper-tab-purchases")
  end

  test "a signed month has no portal-filing task", %{
    conn: conn,
    org: org,
    user: user,
    client: client,
    client_month: client_month
  } do
    {:ok, sales} =
      SalesMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "reviewed"
      })

    scope = Nila.Accounts.Scope.for_user(user)
    month = settle_register!(client_month, user.id)

    month =
      choose_itc_treatment!(month, scope, %{
        "choice" => "later",
        "later_reason" => "review_pending"
      })

    answer_sales_issues!(sales, user.id)
    assert {:ok, _} = Signoffs.sign_off(month, scope)

    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}/gstr3b")

    assert doors(view) == []
    assert has_element?(view, "#gstr3b-primary-filing")
    assert has_element?(view, "#month-deadline-sales", "GSTR-1")
    assert has_element?(view, "#month-deadline-purchase", "GSTR-3B")
    assert has_element?(view, "#month-exit-gstr3b", "Signed by")
    refute has_element?(view, "#gstr1-mark-filed")
    refute has_element?(view, "#gst-mark-filed")
  end

  test "the operator cannot sign GSTR-3B", %{client: client, org: org} do
    member = user_fixture()
    {:ok, _} = Nila.Orgs.add_user(org, member.id, "member")
    conn = log_in_user(Phoenix.ConnTest.build_conn(), member)

    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}/gstr3b")

    refute has_element?(view, "#month-door-sign-3b")
    render_click(view, "3b-sign-off", %{})
    assert render(view) =~ "permission"

    {:ok, month} = ClientMonths.get_by_period(org.id, client.id, @period)
    assert month.state == "worked"
  end

  defp doors(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[id^='month-door-']")
    |> LazyHTML.attribute("id")
  end

  defp read_fixture_json(file) do
    @dir |> Path.join(file) |> File.read!() |> Jason.decode!()
  end
end
