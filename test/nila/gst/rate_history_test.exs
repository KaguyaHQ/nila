defmodule Nila.Gst.RateHistoryTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Hsn.Validation
  alias Nila.Gst.RateHistory
  alias Nila.Gst.Sales.{Gstr1, Workings}

  @header Gstr1.production_header("33AEWPH4158J1Z3", "2025-10")

  test "flags the silver-rod specimen without claiming which rate is legally correct" do
    invoices = [
      invoice("133/2025-26", 18, 2_400),
      invoice("135/2025-26", 3, 600)
    ]

    [issue] = Validation.summary_issues(invoices)

    assert issue["code"] == "hsn_multiple_rates"
    assert issue["message"] =~ "HSN/SAC 71069290 appears at 3% and 18%"
    assert issue["message"] =~ "133/2025-26, 135/2025-26"

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

  test "summarizes conflicting lines on one invoice as one HSN check" do
    invoice =
      invoice("133/2025-26", 18, 2_400)
      |> Map.update!("line_items", fn lines ->
        lines ++ invoice("other", 3, 600)["line_items"]
      end)

    [issue] = Validation.summary_issues([invoice])
    assert issue["message"] =~ "HSN/SAC 71069290 appears at 3% and 18%"
    assert issue["message"] =~ "across invoices 133/2025-26"
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
