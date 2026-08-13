defmodule Nila.Gst.Filing.HistoryTest do
  use Nila.DataCase, async: true

  import Ecto.Changeset
  import Nila.AccountsFixtures

  alias Nila.Clients
  alias Nila.Gst.Filing.History, as: FilingRegister
  alias Nila.Gst.Purchase.Months, as: ClientMonths
  alias Nila.Gst.Sales.Months, as: SalesMonths
  alias Nila.Repo

  setup do
    %{org: org} = user_with_org_fixture()
    %{org: org}
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

  defp filed!(month, arn, filed_at) do
    month
    |> change(state: "filed", filed_at: filed_at, filing_arn: arn)
    |> Repo.update!()
  end

  test "returns independent filing facts for every sales and purchase combination", %{org: org} do
    zed = client!(org, "Zed Foods")
    alpha = client!(org, "alpha Works")
    r1_date = ~U[2025-07-10 10:00:00.000000Z]
    gstr3b_date = ~U[2025-07-18 10:00:00.000000Z]

    purchase!(org, alpha, "2025-12") |> filed!("3B-12", gstr3b_date)
    sales!(org, alpha, "2025-12") |> filed!("R1-12", r1_date)

    purchase!(org, alpha, "2025-11")
    sales!(org, alpha, "2025-11") |> filed!("R1-11", r1_date)

    purchase!(org, alpha, "2025-10") |> filed!("3B-10", gstr3b_date)
    sales!(org, alpha, "2025-10")

    purchase!(org, alpha, "2025-09")
    sales!(org, alpha, "2025-09")

    sales!(org, alpha, "2025-08") |> filed!("R1-08", r1_date)
    sales!(org, alpha, "2025-07")
    purchase!(org, alpha, "2025-06") |> filed!("3B-06", gstr3b_date)
    purchase!(org, alpha, "2025-05")

    assert %{periods: periods, rows: [alpha_row, zed_row]} = FilingRegister.grid(org.id)
    assert periods == ~w(2025-12 2025-11 2025-10 2025-09 2025-08 2025-07 2025-06 2025-05)
    assert alpha_row.client_name == "alpha Works"
    assert zed_row == %{client_id: zed.id, client_name: "Zed Foods", cells: %{}}

    assert alpha_row.cells["2025-12"] == %{
             gstr1: {:filed, r1_date, "R1-12"},
             gstr3b: {:filed, gstr3b_date, "3B-12"}
           }

    assert alpha_row.cells["2025-11"] == %{
             gstr1: {:filed, r1_date, "R1-11"},
             gstr3b: :not_filed
           }

    assert alpha_row.cells["2025-10"] == %{
             gstr1: :not_filed,
             gstr3b: {:filed, gstr3b_date, "3B-10"}
           }

    assert alpha_row.cells["2025-09"] == %{gstr1: :not_filed, gstr3b: :not_filed}
    assert alpha_row.cells["2025-08"] == %{gstr1: {:filed, r1_date, "R1-08"}, gstr3b: :absent}
    assert alpha_row.cells["2025-07"] == %{gstr1: :not_filed, gstr3b: :absent}
    assert alpha_row.cells["2025-06"] == %{gstr1: :absent, gstr3b: {:filed, gstr3b_date, "3B-06"}}
    assert alpha_row.cells["2025-05"] == %{gstr1: :absent, gstr3b: :not_filed}
  end

  test "caps newest-first periods at twelve", %{org: org} do
    client = client!(org, "Breeze Tech")
    periods = ["2025-01" | Enum.map(1..12, &"2024-#{String.pad_leading(to_string(&1), 2, "0")}")]

    Enum.each(periods, &sales!(org, client, &1))

    grid = FilingRegister.grid(org.id)

    assert length(grid.periods) == 12
    assert hd(grid.periods) == "2025-01"
    assert List.last(grid.periods) == "2024-02"
    refute "2024-01" in grid.periods
  end

  test "does not include another org's clients, months, or periods", %{org: org} do
    local = client!(org, "Local Co")
    sales!(org, local, "2025-08")

    %{org: other_org} = user_with_org_fixture(%{org: %{gstin: "27ABCDE1234F1Z0"}})
    foreign = client!(other_org, "Foreign Co")
    sales!(other_org, foreign, "2099-12")

    assert %{periods: ["2025-08"], rows: [%{client_name: "Local Co"}]} =
             FilingRegister.grid(org.id)
  end
end
