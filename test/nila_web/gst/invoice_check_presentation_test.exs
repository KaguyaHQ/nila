defmodule NilaWeb.Gst.InvoiceCheckPresentationTest do
  use ExUnit.Case, async: true
  alias NilaWeb.Gst.InvoiceCheckPresentation, as: InvoiceChecks
  alias Nila.Gst.Extraction.Sales.Normalizer

  defp invoice do
    Normalizer.normalize(%{
      "data" => %{
        "invoice_number" => "TEST-1",
        "invoice_date" => "15.07.2026",
        "document_type" => "invoice",
        "supply_type" => "taxable",
        "printed_total_taxable" => 1000,
        "printed_total_tax" => 180,
        "printed_grand_total" => 1180,
        "line_items" => [
          %{
            "description" => "Service",
            "hsn_sac" => "998719",
            "printed_taxable_value" => 1000,
            "cgst_rate" => 9,
            "sgst_rate" => 9,
            "cgst_amount" => 90,
            "sgst_amount" => 90
          }
        ]
      }
    })
  end

  test "exposes actual comparisons with operands" do
    rows = InvoiceChecks.results(invoice())
    assert Enum.all?(rows, &(&1.status == :passed))
    assert Enum.any?(rows, &(&1.label == "Line 1 tax"))
    assert Enum.any?(rows, &String.contains?(&1.detail, "1,000.00"))
  end

  test "missing printed totals are not presented as passed" do
    rows =
      invoice()
      |> Map.drop(~w(printed_total_taxable printed_total_tax printed_grand_total))
      |> InvoiceChecks.results()

    assert Enum.all?(Enum.take(rows, 3), &(&1.status == :unavailable))

    assert Enum.map(Enum.take(rows, 3), & &1.label) == [
             "Taxable total",
             "GST total",
             "Invoice total"
           ]

    assert Enum.all?(
             Enum.take(rows, 3),
             &String.contains?(String.downcase(&1.detail), "printed amount was not read")
           )
  end

  test "accepted differences explain the tolerance instead of claiming equality" do
    row =
      invoice()
      |> Map.put("printed_grand_total", 1180.04)
      |> InvoiceChecks.results()
      |> Enum.find(&(&1.label == "Invoice total"))

    assert row.status == :passed
    assert row.title == "Invoice total within tolerance"
    assert row.difference == "₹0.04 difference · Allowed ₹0.50"
    exact = InvoiceChecks.results(invoice()) |> Enum.find(&(&1.label == "Invoice total"))
    assert exact.title == "Invoice total matches"
    assert is_nil(exact.difference)
  end

  test "a total discrepancy remains a failed comparison" do
    rows = invoice() |> Map.put("printed_grand_total", 1200) |> InvoiceChecks.results()
    assert Enum.find(rows, &(&1.label == "Invoice total")).status == :failed
    assert Enum.find(rows, &(&1.label == "Taxable total")).status == :passed
  end
end
