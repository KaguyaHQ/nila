defmodule NilaWeb.Gst.MonthLivePurchaseRealFixtureTest do
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Nila.GstFixtures

  alias Nila.Clients
  alias Nila.Gst.Filing.Signoffs
  alias Nila.Gst.Purchase.Months, as: ClientMonths
  alias Nila.Gst.Sales.Months, as: SalesMonths

  @dir "tmp/register/breeze-2025-10"
  @period "2025-10"

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{org_id: org.id, name: "Breeze Tech", type: "company"})

    gstr2b_arrived!(org, client, @period)

    {:ok, _month} =
      ClientMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "worked",
        register_rows: read_json("register_rows.json"),
        recon: read_json("recon.json"),
        summary: read_json("summary.json")
      })

    %{
      conn: log_in_user(conn, user),
      user: user,
      org: org,
      client: client
    }
  end

  test "owner signs off the real worked month through both returns", %{
    conn: conn,
    client: client,
    org: org,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    refute has_element?(view, "#month-door-sign-3b")
    assert has_element?(view, "#month-exit-gstr3b-blocked")
    assert has_element?(view, "#month-exit-gstr3b h3", "GSTR-3B sign-off")
    assert has_element?(view, "#gstr3b-blocker-no-sales")

    {:ok, sales} =
      SalesMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "reviewed",
        invoices: []
      })

    {:ok, month} = ClientMonths.get_by_period(org.id, client.id, @period)

    clean_recon =
      month.recon
      |> Map.put("needs_human", [])
      |> Map.put("in_2b_not_books", [])
      |> Map.put("in_books_not_2b", [])
      |> Map.put("value_mismatch", [])

    {:ok, _} =
      ClientMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "worked",
        register_rows: month.register_rows,
        recon: clean_recon,
        summary: month.summary
      })

    answer_sales_issues!(sales, user.id)

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    assert doors(view) == ["month-door-sign-r1"]
    assert has_element?(view, "#month-exit-gstr1 #month-door-sign-r1.btn-primary")
    refute has_element?(view, "#month-verdict #month-door-sign-r1")

    view |> element("#month-door-sign-r1") |> render_click()

    assert doors(view) == ["month-door-file-sales"]
    assert has_element?(view, "#month-door-file-sales[href='#month-exit-gstr1']")
    assert has_element?(view, "#month-register #month-3b #gst-3b-panel")

    html = render(view)
    assert index_of(html, "gst-register") < index_of(html, "month-3b")
    assert index_of(html, "month-3b") < index_of(html, "month-exit-gstr3b")

    view |> element("#gstr1-mark-filed") |> render_submit(%{"arn" => "R1-ARN"})

    assert doors(view) == ["month-door-sign-3b"]
    assert has_element?(view, "#month-exit-gstr3b #month-door-sign-3b.btn-primary")
    refute has_element?(view, "#month-verdict #month-door-sign-3b")

    view |> element("#month-door-sign-3b") |> render_click()

    assert doors(view) == ["month-door-file-purchase"]
    assert has_element?(view, "#month-door-file-purchase[href='#month-exit-gstr3b']")
    assert has_element?(view, "#month-exit-gstr3b a[target='_blank'][rel='noopener']")
    assert has_element?(view, "#gst-filed-arn")
    refute has_element?(view, "#month-door-sign-3b")
    assert has_element?(view, "#month-exit-gstr3b", "Signed by")

    {:ok, month} = ClientMonths.get_by_period(org.id, client.id, @period)
    assert month.state == "reviewed"
    assert {:ok, signoff} = Signoffs.latest_signoff(month.id)
    assert Map.has_key?(signoff.snapshot, "gstr3b")
  end

  defp read_json(file) do
    @dir |> Path.join(file) |> File.read!() |> Jason.decode!()
  end

  defp index_of(html, id) do
    [start, _rest] = String.split(html, ~s(id="#{id}"), parts: 2)
    String.length(start)
  end

  defp doors(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[id^='month-door-']")
    |> LazyHTML.attribute("id")
  end
end
