defmodule Nila.Gst.SalesResolutionsTest do
  use Nila.DataCase, async: true
  use Oban.Testing, repo: Nila.Repo

  import Nila.AccountsFixtures

  alias Nila.Clients
  alias Nila.Gst.{Gstr1Worker, SalesMonths, SalesResolutions, SalesWorkings}
  alias Nila.Storage

  @period "2026-05"

  setup do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Breeze Tech",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    pdf_key = "gstr1/#{org.id}/#{client.id}/#{@period}/source/bills.pdf"
    {:ok, _} = Storage.put(pdf_key, "%PDF-1.4 fake bytes")

    :ok =
      perform_job(Gstr1Worker, %{
        "org_id" => org.id,
        "client_id" => client.id,
        "period" => @period,
        "pdf_key" => pdf_key
      })

    {:ok, month} = SalesMonths.get_by_period(org.id, client.id, @period)
    %{user: user, org: org, client: client, month: month}
  end

  defp confirm_all_open(month, user) do
    SalesResolutions.workings(month).issues
    |> Enum.filter(&(&1["status"] == "open" and &1["level"] != "info"))
    |> Enum.each(fn issue ->
      {:ok, _} =
        SalesResolutions.record(
          month,
          %{"verb" => "confirm_issue", "target" => SalesWorkings.issue_key(issue)},
          user.id
        )
    end)
  end

  test "workings replays recorded decisions over the stored month", %{
    month: month,
    user: user
  } do
    before = SalesResolutions.workings(month)
    poison = Enum.find(before.issues, &(&1["code"] == "grand_total_mismatch"))
    assert poison["status"] == "open"

    {:ok, _} =
      SalesResolutions.record(
        month,
        %{"verb" => "confirm_issue", "target" => SalesWorkings.issue_key(poison)},
        user.id
      )

    replayed = SalesResolutions.workings(month)
    poison = Enum.find(replayed.issues, &(&1["code"] == "grand_total_mismatch"))
    assert poison["status"] == "resolved"

    assert %{invoices: [_ | _]} = Repo.reload!(month)
  end

  test "mark_reviewed refuses while issues are open, then flips the state", %{
    month: month,
    user: user
  } do
    assert {:error, :open_issues} = SalesResolutions.mark_reviewed(month)

    confirm_all_open(month, user)

    assert {:ok, reviewed} = SalesResolutions.mark_reviewed(month)
    assert reviewed.state == "reviewed"
  end

  test "a new decision demotes a reviewed month back to worked", %{month: month, user: user} do
    confirm_all_open(month, user)
    {:ok, reviewed} = SalesResolutions.mark_reviewed(month)

    issue = List.first(SalesResolutions.workings(reviewed).issues)

    {:ok, _} =
      SalesResolutions.record(
        reviewed,
        %{"verb" => "reopen", "target" => SalesWorkings.issue_key(issue)},
        user.id
      )

    assert Repo.reload!(reviewed).state == "worked"
  end

  test "3B liability reads through the review loop with honest provenance", %{
    org: org,
    client: client,
    month: month,
    user: user
  } do
    {:ok, client_month} =
      Nila.Gst.ClientMonths.upsert(%{
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
        }
      })

    assert Nila.Gst.Resolutions.workings(client_month).gstr3b["liability_source"] ==
             "gstr1_derived"

    confirm_all_open(month, user)
    {:ok, _} = SalesResolutions.mark_reviewed(month)

    assert Nila.Gst.Resolutions.workings(client_month).gstr3b["liability_source"] ==
             "gstr1_reviewed"
  end
end
