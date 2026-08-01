defmodule Nila.Gst.RateHistoryTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.RateHistory
  alias Nila.Gst.Sales.{Gstr1, Workings}

  @header Gstr1.production_header("33AEWPH4158J1Z3", "2025-10")

  test "flags the silver-rod specimen without claiming which rate is legally correct" do
    invoices = [
      invoice("133/2025-26", 18, 2_400),
      invoice("135/2025-26", 3, 600)
    ]

    issues = RateHistory.issues(invoices)

    assert length(issues) == 2

    issue_133 = Enum.find(issues, &(&1["invoice"] == "133/2025-26"))
    assert issue_133["code"] == "rate_history_conflict"
    assert issue_133["message"] =~ "71069290 at 18%"
    assert issue_133["message"] =~ "3% on invoice 135/2025-26"
    assert issue_133["message"] =~ "history check alone does not establish"

    result = Workings.materialize(invoices, [], @header, [], %{rate_history: []})
    refute Workings.reviewable?(result.issues)
  end

  test "stays quiet when the same item and code keep the same rate" do
    invoices = [invoice("133/2025-26", 3, 2_400), invoice("135/2025-26", 3, 600)]
    assert RateHistory.issues(invoices) == []
  end

  test "uses prior-period observations as precedent" do
    prior = RateHistory.observations([invoice("90/2025-26", 3, 1_000)], "2025-09")
    [issue] = RateHistory.issues([invoice("133/2025-26", 18, 2_400)], prior)

    assert issue["message"] =~ "invoice 90/2025-26 (2025-09)"
  end

  test "describes conflicting lines on one invoice without a circular invoice reference" do
    invoice =
      invoice("133/2025-26", 18, 2_400)
      |> Map.update!("line_items", fn lines ->
        lines ++ invoice("other", 3, 600)["line_items"]
      end)

    [issue] = RateHistory.issues([invoice])
    assert issue["message"] =~ "elsewhere on this invoice"
    refute issue["message"] =~ "on invoice 133/2025-26"
  end

  defp invoice(number, rate, taxable) do
    half = if rem(rate, 2) == 0, do: div(rate, 2), else: rate / 2
    side_tax = Float.round(taxable * half / 100, 2)

    %{
      "invoice_number" => number,
      "invoice_date" => ~D[2025-10-08],
      "seller_gstin" => "33AEWPH4158J1Z3",
      "buyer_gstin" => "33AABCP9487A1ZG",
      "printed_total_taxable" => taxable,
      "printed_total_tax" => side_tax * 2,
      "printed_grand_total" => taxable + side_tax * 2,
      "line_items" => [
        %{
          "description" => "Silver Rod 43%",
          "hsn_sac" => "71069290",
          "taxable_value" => taxable,
          "cgst_rate" => half,
          "cgst_amount" => side_tax,
          "sgst_rate" => half,
          "sgst_amount" => side_tax,
          "igst_rate" => nil,
          "igst_amount" => nil
        }
      ]
    }
  end
end
