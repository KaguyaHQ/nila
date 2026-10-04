defmodule Nila.Gst.Sales.Tally.HistoryTest do
  use Nila.DataCase, async: true
  import Nila.AccountsFixtures
  alias Nila.Gst.Sales.Tally.History
  alias Nila.{Repo, TallyDevices}
  alias Nila.TallyDevices.{SyncedMaster, SyncedVoucher, SyncRun}

  test "dated HSN settings and same-party usage select a unique sales ledger" do
    ledger = sales("labour")
    history = History.build([ledger, tax()], [voucher("labour")])
    assert %{ledger: ^ledger, history_count: 1} = History.sales(history, invoice(), line())

    assert %{ledger: nil} =
             History.sales(history, Map.put(invoice(), "invoice_date", "2026-05-01"), line())

    assert %{ledger: nil, suggestion: ^ledger} =
             History.sales(history, Map.put(invoice(), "buyer_gstin", "NEW"), line())

    assert %{ledger: nil, suggestion: ^ledger} =
             History.sales(history, Map.put(invoice(), "buyer_gstin", nil), line())
  end

  test "ambiguous usage does not choose the most frequent ledger" do
    a = sales("a")
    b = sales("b")
    history = History.build([a, b, tax()], [voucher("a"), voucher("a"), voucher("b")])
    assert %{ledger: nil, suggestion: nil} = History.sales(history, invoice(), line())
  end

  test "tax proposals use duty head, exact rate and positive sales usage" do
    output = tax()
    input = %{output | name: "input", identity: "input"}
    history = History.build([output, input], [voucher("labour")])
    assert %{ledger: ^output, history_count: 1} = History.tax(history, "igst", 18)
    assert %{ledger: nil} = History.tax(history, "igst", 5)
    refute History.tax_rate_matches?(output, "cgst", 18)
    refute History.tax_rate_matches?(output, "igst", 5)

    assert length(
             History.rates(
               [
                 %{"igst_amount" => 1, "igst_rate" => "9"},
                 %{"igst_amount" => 1, "igst_rate" => "9.0"}
               ],
               "igst"
             )
           ) == 1
  end

  test "database history excludes future dates, other companies and unfinished snapshots" do
    %{org: org} = user_with_org_fixture()
    {:ok, device, _} = TallyDevices.create_device(org, %{name: "PC"})
    {:ok, [a, b]} = TallyDevices.report_companies(device, [%{"name" => "A"}, %{"name" => "B"}])

    for {company, status, date, identity} <- [
          {a, "succeeded", ~D[2026-07-01], "prior"},
          {a, "succeeded", ~D[2026-08-01], "current"},
          {b, "succeeded", ~D[2026-07-01], "other"},
          {a, "running", ~D[2026-07-01], "partial"}
        ] do
      run =
        Repo.insert!(%SyncRun{
          org_id: org.id,
          device_id: device.id,
          company_id: company.id,
          status: status,
          period_start: date,
          period_end: date,
          started_at: DateTime.utc_now()
        })

      Repo.insert!(%SyncedVoucher{
        org_id: org.id,
        company_id: company.id,
        identity: identity,
        date: date,
        voucher_type: "Sales",
        last_seen_sync_id: run.id
      })
    end

    assert Enum.map(History.load(org.id, a.id, "2026-08", []).vouchers, & &1.identity) == [
             "prior"
           ]
  end

  defp invoice, do: %{"invoice_date" => "2026-08-01", "buyer_gstin" => "PARTY"}
  defp line, do: %{"hsn_sac" => "998719", "igst_rate" => 18, "igst_amount" => 180}

  defp sales(name) do
    %SyncedMaster{
      name: name,
      identity: name,
      data: %{
        "parent" => "Sales Accounts",
        "hsn_details" => [
          %{
            "source" => "Specify Details Here",
            "hsnCode" => "9987",
            "applicableFrom" => "2020-01-01"
          },
          %{
            "source" => "Specify Details Here",
            "hsnCode" => "998719",
            "applicableFrom" => "2026-06-01"
          }
        ],
        "gst_details" => [
          %{
            "sourceOfGSTDetails" => "Specify Details Here",
            "applicableFrom" => "2020-01-01",
            "stateWiseDetails" => [
              %{
                "stateName" => "Any",
                "gstRateDetails" => [%{"dutyHead" => "IGST", "gstRate" => 18}]
              }
            ]
          }
        ]
      }
    }
  end

  defp tax,
    do: %SyncedMaster{
      name: "output",
      identity: "output",
      data: %{"tax_type" => "GST", "gst_duty_head" => "IGST", "rate_of_tax" => 18}
    }

  defp voucher(name),
    do: %SyncedVoucher{
      data: %{
        "party_gstin" => "PARTY",
        "ledger_entries" => [
          %{"ledger_name" => name, "amount" => "1000"},
          %{"ledger_name" => "output", "amount" => "180"}
        ]
      }
    }
end
