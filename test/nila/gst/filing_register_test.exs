defmodule Nila.Gst.FilingRegisterTest do
  use Nila.DataCase, async: true

  import Ecto.Changeset
  import Nila.AccountsFixtures

  alias Nila.Clients
  alias Nila.Gst.{ClientMonths, FilingRegister, SalesMonths}
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

  defp filed!(month, arn) do
    month
    |> change(state: "filed", filed_at: ~U[2025-11-01 10:00:00.000000Z], filing_arn: arn)
    |> Repo.update!()
  end

  test "merges both return sides, keeps the roster, and derives every cell state", %{org: org} do
    zed = client!(org, "Zed Foods")
    alpha = client!(org, "alpha Works")

    purchase!(org, alpha, "2025-08") |> filed!("3B-08")
    sales!(org, alpha, "2025-08") |> filed!("R1-08")

    purchase!(org, alpha, "2025-07")
    sales!(org, alpha, "2025-07") |> filed!("R1-07")

    sales!(org, alpha, "2025-06") |> filed!("R1-06")
    purchase!(org, alpha, "2025-05") |> filed!("3B-05")
    purchase!(org, alpha, "2025-04")
    sales!(org, alpha, "2025-04")

    assert %{periods: ["2025-08", "2025-07", "2025-06", "2025-05", "2025-04"], rows: rows} =
             FilingRegister.grid(org.id)

    assert [alpha_row, zed_row] = rows
    assert alpha_row.client_name == "alpha Works"
    assert zed_row == %{client_id: zed.id, client_name: "Zed Foods", cells: %{}}

    assert alpha_row.cells["2025-08"] == %{
             state: :filed,
             r1_filed: true,
             gstr3b_filed: true,
             r1_arn: "R1-08",
             gstr3b_arn: "3B-08"
           }

    assert alpha_row.cells["2025-07"].state == :partial
    assert alpha_row.cells["2025-07"].r1_filed
    refute alpha_row.cells["2025-07"].gstr3b_filed
    assert alpha_row.cells["2025-06"].state == :filed
    assert alpha_row.cells["2025-05"].state == :filed
    assert alpha_row.cells["2025-04"].state == :open
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
