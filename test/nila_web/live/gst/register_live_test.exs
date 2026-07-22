defmodule NilaWeb.Gst.RegisterLiveTest do
  use NilaWeb.ConnCase, async: true

  import Ecto.Changeset
  import Phoenix.LiveViewTest

  alias Nila.Clients
  alias Nila.Gst.Purchase.Months, as: ClientMonths
  alias Nila.Gst.Sales.Months, as: SalesMonths
  alias Nila.Repo

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()
    %{conn: log_in_user(conn, user), org: org}
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

  defp filed!(month, arn) do
    month
    |> change(state: "filed", filed_at: ~U[2025-11-01 10:00:00.000000Z], filing_arn: arn)
    |> Repo.update!()
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

  test "a filed month links to its workbench and exposes both ARNs", %{conn: conn, org: org} do
    client = client!(org, "Breeze Tech")
    purchase!(org, client, "2025-08") |> filed!("3B-ARN-08")
    sales!(org, client, "2025-08") |> filed!("R1-ARN-08")

    {:ok, view, _html} = live(conn, ~p"/register")

    link = "#register-link-#{client.id}-2025-08"
    assert has_element?(view, link, "filed")
    assert has_element?(view, ~s|#{link}[href="/gst/#{client.id}/2025-08"]|)

    assert has_element?(
             view,
             ~s|#{link}[title="GSTR-1 ARN: R1-ARN-08 · GSTR-3B ARN: 3B-ARN-08"]|
           )
  end

  test "partial cells identify whether R1 or 3B was filed", %{conn: conn, org: org} do
    client = client!(org, "Breeze Tech")

    purchase!(org, client, "2025-08")
    sales!(org, client, "2025-08") |> filed!("R1-ARN")

    purchase!(org, client, "2025-07") |> filed!("3B-ARN")
    sales!(org, client, "2025-07")

    {:ok, view, _html} = live(conn, ~p"/register")

    assert has_element?(view, "#register-cell-#{client.id}-2025-08 .badge-warning", "R1")
    assert has_element?(view, "#register-cell-#{client.id}-2025-07 .badge-warning", "3B")
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
