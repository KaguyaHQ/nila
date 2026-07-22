defmodule Nila.Gst.WorkQueueTest do
  use Nila.DataCase, async: true

  import Nila.AccountsFixtures
  import Nila.GstFixtures

  alias Nila.Accounts.Scope
  alias Nila.Clients
  alias Nila.Gst.Filing.{Calendar, Signoffs}
  alias Nila.Gst.Purchase.Months, as: ClientMonths
  alias Nila.Gst.Sales.Months, as: SalesMonths
  alias Nila.Gst.Sales.Resolutions, as: SalesResolutions
  alias Nila.Gst.Sales.Workings, as: SalesWorkings
  alias Nila.Gst.WorkQueue, as: Today

  @period "2025-10"
  @today ~D[2025-11-05]

  setup do
    %{user: owner, org: org, membership: membership} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Breeze Tech",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    %{
      org: org,
      client: client,
      scope: %Scope{user: owner, current_org: org, membership: membership}
    }
  end

  defp seed_clean_month(org, client, user_id) do
    {:ok, month} =
      ClientMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "worked",
        recon: %{
          "matched" => [],
          "value_mismatch" => [],
          "needs_human" => [],
          "in_books_not_2b" => [],
          "in_2b_not_books" => []
        },
        summary: %{"buckets" => %{"matched" => 1}}
      })

    work_dump!(org, client, @period, "sales", "%PDF-1.4 fake bytes", user_id)

    {:ok, sales_month} = SalesMonths.get_by_period(org.id, client.id, @period)

    SalesResolutions.workings(sales_month).issues
    |> Enum.filter(&(&1["status"] == "open" and &1["level"] != "info"))
    |> Enum.each(fn issue ->
      {:ok, _} =
        SalesResolutions.record(
          sales_month,
          %{"verb" => "confirm_issue", "target" => SalesWorkings.issue_key(issue)},
          user_id
        )
    end)

    {:ok, _} = SalesResolutions.mark_reviewed(sales_month)

    month
  end

  defp row_for(org, client) do
    org.id |> Today.rows(@today) |> Enum.find(&(&1.client_id == client.id))
  end

  test "closeable period is the previous calendar month" do
    assert Calendar.closeable_period(~D[2025-11-05]) == "2025-10"
    assert Calendar.closeable_period(~D[2025-11-30]) == "2025-10"
    assert Calendar.closeable_period(~D[2025-12-01]) == "2025-11"
  end

  test "a signed-unfiled month lands in to_file; filing both returns moves it to done", %{
    org: org,
    client: client,
    scope: scope
  } do
    month = seed_clean_month(org, client, scope.user.id)
    assert row_for(org, client).section == :waiting_on_senior

    {:ok, _} = Signoffs.sign_off(month, scope)
    row = row_for(org, client)
    assert row.section == :to_file
    assert row.deadline.return == "GSTR-1"

    {:ok, month} = ClientMonths.get_by_period(org.id, client.id, @period)
    {:ok, _} = Signoffs.mark_filed(month, scope, nil)

    # 3B filed but the R1 has no signature — still in the filing gap? No:
    # the R1 was never signed, so nothing is signed-unfiled. The sales month
    # is reviewed and unfiled, so the month is waiting on the senior's R1
    # signature. The chip now counts the unfiled R1.
    row = row_for(org, client)
    assert row.section == :waiting_on_senior
    assert row.deadline.return == "GSTR-1"

    {:ok, sales_month} = SalesMonths.get_by_period(org.id, client.id, @period)
    {:ok, _} = Signoffs.sign_off_gstr1(sales_month, scope)
    assert row_for(org, client).section == :to_file

    {:ok, sales_month} = SalesMonths.get_by_period(org.id, client.id, @period)
    {:ok, _} = Signoffs.mark_filed(sales_month, scope, nil)

    row = row_for(org, client)
    assert row.section == :done
    assert row.deadline == nil
  end

  test "a fully filed old month drops off the list", %{org: org, client: client, scope: scope} do
    month = seed_clean_month(org, client, scope.user.id)
    {:ok, _} = Signoffs.sign_off(month, scope)
    {:ok, month} = ClientMonths.get_by_period(org.id, client.id, @period)
    {:ok, _} = Signoffs.mark_filed(month, scope, nil)
    {:ok, sales_month} = SalesMonths.get_by_period(org.id, client.id, @period)
    {:ok, _} = Signoffs.sign_off_gstr1(sales_month, scope)
    {:ok, sales_month} = SalesMonths.get_by_period(org.id, client.id, @period)
    {:ok, _} = Signoffs.mark_filed(sales_month, scope, nil)

    # @period is closeable as of @today — the done row shows. A month later
    # it is history and drops off; the client's row is for the new period.
    assert row_for(org, client).section == :done

    december = ~D[2025-12-05]
    rows = org.id |> Today.rows(december) |> Enum.filter(&(&1.client_id == client.id))
    assert [row] = rows
    assert row.period == "2025-11"
    assert row.section == :waiting_on_client
  end

  test "an unfiled old month stays on the list next to the new period", %{
    org: org,
    client: client,
    scope: scope
  } do
    seed_clean_month(org, client, scope.user.id)

    december = ~D[2025-12-05]
    rows = org.id |> Today.rows(december) |> Enum.filter(&(&1.client_id == client.id))

    assert Enum.map(rows, & &1.period) |> Enum.sort() == ["2025-10", "2025-11"]
  end
end
