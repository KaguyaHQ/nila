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

  test "owner signs the real purchase month using its recorded R1 dependency", %{
    conn: conn,
    client: client,
    org: org,
    user: user
  } do
    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}/gstr3b")

    refute has_element?(view, "#month-door-sign-3b")
    assert has_element?(view, "#month-exit-gstr3b-blocked")
    refute has_element?(view, "#month-exit-gstr3b")
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

    {:ok, month} =
      ClientMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "worked",
        register_rows: month.register_rows,
        recon: clean_recon,
        summary: month.summary
      })

    scope = Nila.Accounts.Scope.for_user(user)

    for line <- Nila.Gst.Purchase.Resolutions.workings(month).case_lines,
        line.document_type in ~w(invoice debit_note),
        Enum.sum(Map.values(line.outstanding_heads)) > 0 do
      attrs =
        if line.claimable?,
          do: %{"choice" => "claim"},
          else: %{"choice" => "later", "later_reason" => "review_pending"}

      assert {:ok, _} =
               Nila.Gst.Purchase.ItcDecisions.apply(
                 scope,
                 client.id,
                 @period,
                 [line.case_id],
                 attrs
               )
    end

    answer_sales_issues!(sales, user.id)

    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}/gstr3b")

    assert doors(view) == ["month-door-sign-3b"]

    assert has_element?(
             view,
             "#month-3b #month-door-sign-3b.nila-button[data-variant='primary']"
           )

    refute has_element?(view, "#month-verdict #month-door-sign-3b")

    view |> element("#month-door-sign-3b") |> render_click()

    assert doors(view) == []
    refute has_element?(view, "#gst-mark-filed")
    refute has_element?(view, "#month-exit-gstr3b", "Filing ARN")
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

  defp doors(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[id^='month-door-']")
    |> LazyHTML.attribute("id")
  end
end
