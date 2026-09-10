defmodule Nila.Gst.WorkQueueTest do
  use Nila.DataCase, async: true

  import Nila.AccountsFixtures
  import Nila.GstFixtures

  alias Nila.Accounts.Scope
  alias Nila.Clients
  alias Nila.Gst.Filing.{Calendar, Signoffs}
  alias Nila.Gst.Purchase.Months, as: ClientMonths
  alias Nila.Gst.Sales.Months, as: SalesMonths
  alias Nila.Gst.Sales.Review.Resolutions, as: SalesResolutions
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

    answer_sales_issues!(sales_month, user_id)

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

  describe "purchase track: decisions versus collection" do
    defp purchase_facts(overrides) do
      # A reviewed sales side, so the fold reflects the purchase track under test
      # rather than an absent GSTR-1 that is itself a client wait.
      %{
        purchase: %{id: 1},
        sales: %{id: 1, state: "filed"},
        need_decision: 0,
        awaiting_bills: 0,
        gstr2b_in: true,
        gstr2b_available: true,
        r1_filed: true,
        gstr3b_signed: false,
        gstr3b_filed: false
      }
      |> Map.merge(Map.new(overrides))
    end

    test "rows a reviewer can judge are the reviewer's work" do
      tracks = Today.track_states(purchase_facts(need_decision: 3))

      assert tracks.purchase == :open
      assert Today.fold_state(tracks) == :needs_you
    end

    # A bill the portal reported and nobody supplied has no document to open and
    # nothing to compare. It names the client, so it must not land in the pile a
    # junior is told to work.
    test "bills nobody supplied wait on the client, not the reviewer" do
      tracks = Today.track_states(purchase_facts(awaiting_bills: 8))

      assert tracks.purchase == :awaiting_bills
      assert Today.fold_state(tracks) == :waiting_on_client
    end

    test "a real decision outranks a chase when the month holds both" do
      tracks = Today.track_states(purchase_facts(need_decision: 2, awaiting_bills: 8))

      assert tracks.purchase == :open
      assert Today.fold_state(tracks) == :needs_you
    end

    test "nothing open at all is clear, waiting on a signature" do
      tracks = Today.track_states(purchase_facts([]))

      assert tracks.purchase == :clear
      assert Today.fold_state(tracks) == :waiting_on_senior
    end

    test "a concrete unresolved sales packet is work, not a client attestation wait" do
      tracks =
        Today.track_states(
          purchase_facts(
            sales: %{id: 1, state: "reviewed"},
            r1_filed: false,
            sales_intake_open: true
          )
        )

      assert tracks.sales == :open
      assert Today.fold_state(tracks) == :needs_you
    end

    # The 2B gates everything behind it: with no portal side, every books row is
    # unmatched and the counts underneath mean nothing yet.
    test "a missing 2B still outranks both" do
      tracks =
        Today.track_states(purchase_facts(need_decision: 5, awaiting_bills: 8, gstr2b_in: false))

      assert tracks.purchase == :need_2b
    end
  end

  test "a signed-unfiled month lands in to_file; filing both returns moves it to done", %{
    org: org,
    client: client,
    scope: scope
  } do
    month = seed_clean_month(org, client, scope.user.id)
    assert row_for(org, client).section == :to_file

    {:ok, _} = Signoffs.sign_off(month, scope)
    row = row_for(org, client)
    assert row.section == :to_file
    assert row.deadline.return == "GSTR-1"

    {:ok, month} = ClientMonths.get_by_period(org.id, client.id, @period)
    {:ok, _} = Signoffs.mark_filed(month, scope, nil)

    # Resolved GSTR-1 remains ready for filing after the 3B is filed.
    row = row_for(org, client)
    assert row.section == :to_file
    assert row.deadline.return == "GSTR-1"

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
