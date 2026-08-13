defmodule NilaWeb.Gst.RegisterLiveTest do
  use NilaWeb.ConnCase, async: true

  import Ecto.Changeset
  import Phoenix.LiveViewTest

  alias Nila.Clients
  alias Nila.Gst.Filing.Signoff
  alias Nila.Gst.Purchase.Months, as: ClientMonths
  alias Nila.Gst.Sales.Months, as: SalesMonths
  alias Nila.Repo

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()
    %{conn: log_in_user(conn, user), org: org, user: user}
  end

  defp client!(org, name) do
    {:ok, client} = Clients.create_client(%{org_id: org.id, name: name, type: "company"})
    client
  end

  defp purchase!(org, client, period) do
    {:ok, month} =
      ClientMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: period,
        state: "worked"
      })

    month
  end

  defp sales!(org, client, period) do
    {:ok, month} =
      SalesMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: period,
        state: "worked"
      })

    month
  end

  defp filed!(month, arn, filed_at \\ ~U[2025-07-10 10:00:00.000000Z]) do
    month
    |> change(state: "filed", filed_at: filed_at, filing_arn: arn)
    |> Repo.update!()
  end

  defp signed_gstr1!(month, user) do
    %Signoff{org_id: month.org_id, sales_month_id: month.id, signed_by_id: user.id}
    |> Signoff.changeset(%{artifact: "gstr1", snapshot: %{}})
    |> Repo.insert!()
  end

  defp signed_gstr3b!(month, user) do
    %Signoff{org_id: month.org_id, client_month_id: month.id, signed_by_id: user.id}
    |> Signoff.changeset(%{artifact: "gstr3b", snapshot: %{}})
    |> Repo.insert!()
  end

  test "mounts for a verified org user and renders the ordered rail", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/register")

    assert has_element?(view, "#register-page")
    assert has_element?(view, ~s|a[aria-current="page"][href="/register"]|)

    nav = view |> element("aside nav") |> render()

    assert nav =~
             ~r/href="\/today".*href="\/gst\/upload".*href="\/clients".*href="\/register"/s
  end

  test "redirects logged-out visitors to log in" do
    assert {:error, {:redirect, %{to: "/users/log_in"}}} =
             live(Phoenix.ConnTest.build_conn(), ~p"/register")
  end

  test "each populated cell renders the two return filing facts, dates, ARNs, and link", %{
    conn: conn,
    org: org
  } do
    client = client!(org, "Breeze Tech")
    r1_date = ~U[2025-07-10 10:00:00.000000Z]
    gstr3b_date = ~U[2025-07-18 10:00:00.000000Z]

    purchase!(org, client, "2025-08") |> filed!("3B-ARN-08", gstr3b_date)
    sales!(org, client, "2025-08") |> filed!("R1-ARN-08", r1_date)

    purchase!(org, client, "2025-07")
    sales!(org, client, "2025-07") |> filed!("R1-ARN-07", r1_date)

    purchase!(org, client, "2025-06") |> filed!("3B-ARN-06", gstr3b_date)
    sales!(org, client, "2025-06")

    purchase!(org, client, "2025-05")
    sales!(org, client, "2025-05")

    sales!(org, client, "2025-04") |> filed!("R1-ARN-04", r1_date)
    sales!(org, client, "2025-03")
    purchase!(org, client, "2025-02") |> filed!("3B-ARN-02", gstr3b_date)
    purchase!(org, client, "2025-01")

    {:ok, view, _html} = live(conn, ~p"/register")

    assert has_element?(
             view,
             ~s|#register-link-#{client.id}-2025-08[href="/gst/#{client.id}/2025-08"]|
           )

    assert has_element?(
             view,
             ~s|#register-link-#{client.id}-2025-08[title="GSTR-1 ARN: R1-ARN-08 · GSTR-3B ARN: 3B-ARN-08"]|
           )

    assert has_element?(view, "#register-r1-#{client.id}-2025-08", "10 Jul")
    assert has_element?(view, "#register-3b-#{client.id}-2025-08", "18 Jul")

    assert has_element?(view, "#register-r1-#{client.id}-2025-07", "10 Jul")
    assert has_element?(view, "#register-3b-#{client.id}-2025-07", "Not filed")
    assert has_element?(view, "#register-r1-#{client.id}-2025-06", "Not filed")
    assert has_element?(view, "#register-3b-#{client.id}-2025-06", "18 Jul")
    assert has_element?(view, "#register-r1-#{client.id}-2025-05", "Not filed")
    assert has_element?(view, "#register-3b-#{client.id}-2025-05", "Not filed")
    assert has_element?(view, "#register-r1-#{client.id}-2025-04", "10 Jul")
    assert has_element?(view, "#register-3b-#{client.id}-2025-04", "—")
    assert has_element?(view, "#register-r1-#{client.id}-2025-03", "Not filed")
    assert has_element?(view, "#register-3b-#{client.id}-2025-03", "—")
    assert has_element?(view, "#register-r1-#{client.id}-2025-02", "—")
    assert has_element?(view, "#register-3b-#{client.id}-2025-02", "18 Jul")
    assert has_element?(view, "#register-r1-#{client.id}-2025-01", "—")
    assert has_element?(view, "#register-3b-#{client.id}-2025-01", "Not filed")
  end

  test "signed but unfiled returns still say Not filed", %{conn: conn, org: org, user: user} do
    client = client!(org, "Breeze Tech")
    sales = sales!(org, client, "2025-08")
    purchase = purchase!(org, client, "2025-08")
    signed_gstr1!(sales, user)
    signed_gstr3b!(purchase, user)

    {:ok, view, _html} = live(conn, ~p"/register")

    assert has_element?(view, "#register-r1-#{client.id}-2025-08", "Not filed")
    assert has_element?(view, "#register-3b-#{client.id}-2025-08", "Not filed")
  end

  test "a client without months remains in the roster with an absent cell", %{
    conn: conn,
    org: org
  } do
    worked = client!(org, "Breeze Tech")
    waiting = client!(org, "Cedar Stores")
    sales!(org, worked, "2025-08")

    {:ok, view, _html} = live(conn, ~p"/register")

    assert has_element?(view, "#register-row-#{waiting.id}", "Cedar Stores")
    assert has_element?(view, "#register-cell-#{waiting.id}-2025-08", "—")
    refute has_element?(view, "#register-cell-#{waiting.id}-2025-08 a")
  end

  test "clients with no months still render an all-dash roster row", %{conn: conn, org: org} do
    client = client!(org, "Cedar Stores")

    {:ok, view, _html} = live(conn, ~p"/register")

    assert has_element?(view, "#register-empty")
    assert has_element?(view, "#register-row-#{client.id}", "Cedar Stores")
    assert has_element?(view, "#register-cell-#{client.id}-none", "—")
  end

  test "another org's clients, months, and periods do not appear", %{conn: conn, org: org} do
    local = client!(org, "Local Co")
    sales!(org, local, "2025-08")

    %{org: other_org} = user_with_org_fixture(%{org: %{gstin: "27ABCDE1234F1Z0"}})
    foreign = client!(other_org, "Foreign Co")
    sales!(other_org, foreign, "2099-12") |> filed!("FOREIGN-ARN")

    {:ok, view, _html} = live(conn, ~p"/register")

    assert has_element?(view, "#register-period-2025-08")
    refute has_element?(view, "#register-period-2099-12")
    refute render(view) =~ "Foreign Co"
    refute render(view) =~ "FOREIGN-ARN"
  end

  test "a truly empty org gets the intake empty state without a table", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/register")

    assert has_element?(
             view,
             "#register-empty",
             "No GST months yet — bring in a client's documents and this view fills itself."
           )

    assert has_element?(view, ~s|#register-bring-documents[href="/gst/upload"]|)
    refute has_element?(view, "#register-table")
  end
end
