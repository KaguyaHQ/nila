defmodule Nila.Gst.Sales.ResolutionsTest do
  use Nila.DataCase, async: true

  import Nila.AccountsFixtures
  import Nila.GstFixtures

  alias Nila.Clients
  alias Nila.Gst.Rates.{Release, Rule}
  alias Nila.Gst.Sales.Months, as: SalesMonths
  alias Nila.Gst.Sales.Resolutions, as: SalesResolutions
  alias Nila.Gst.Sales.Workings, as: SalesWorkings

  @period "2025-10"

  setup do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Breeze Tech",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    work_dump!(org, client, @period, "sales", "%PDF-1.4 fake bytes", user.id)

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

  test "workings reloads the rate release pinned on the month", %{month: month} do
    now = DateTime.utc_now()

    release =
      %Release{}
      |> Release.changeset(%{
        notification_number: "9/2025-Integrated Tax (Rate)",
        tax_type: "integrated",
        source_name: "notification.pdf",
        file_sha256: Base.encode16(:crypto.strong_rand_bytes(32)),
        published_on: ~D[2025-09-17],
        effective_from: ~D[2025-09-22],
        observed_at: now
      })
      |> Repo.insert!()

    Repo.insert!(%Rule{
      release_id: release.id,
      serial_number: 3,
      schedule: "IV",
      total_rate: Decimal.new("3"),
      raw_code_expression: "7106",
      raw_description: "Silver",
      parsed_scope: %{
        "includes" => ["7106"],
        "excludes" => [],
        "ranges" => [],
        "any_chapter" => false
      },
      parser_confidence: "automatic"
    })

    [invoice | rest] = month.invoices

    invoice =
      invoice
      |> put_in(["invoice_date"], ~D[2025-10-08])
      |> put_in(["line_items", Access.at(0), "description"], "Silver rod")
      |> put_in(["line_items", Access.at(0), "hsn_sac"], "71069290")
      |> put_in(["line_items", Access.at(0), "hsn_kind"], "hsn")
      |> put_in(["line_items", Access.at(0), "cgst_rate"], 9)
      |> put_in(["line_items", Access.at(0), "sgst_rate"], 9)

    {:ok, month} =
      SalesMonths.upsert(%{
        org_id: month.org_id,
        client_id: month.client_id,
        period: month.period,
        invoices: [invoice | rest],
        gst_rate_release_id: release.id
      })

    workings = SalesResolutions.workings(month)
    assert Enum.any?(workings.issues, &(&1["code"] == "statutory_rate_mismatch"))

    assert get_in(hd(workings.invoices), [
             "line_items",
             Access.at(0),
             "rate_validation",
             "release_id"
           ]) == release.id
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
      Nila.Gst.Purchase.Months.upsert(%{
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

    assert Nila.Gst.Purchase.Resolutions.workings(client_month).gstr3b["liability_source"] ==
             "gstr1_derived"

    confirm_all_open(month, user)
    {:ok, _} = SalesResolutions.mark_reviewed(month)

    assert Nila.Gst.Purchase.Resolutions.workings(client_month).gstr3b["liability_source"] ==
             "gstr1_reviewed"
  end
end
