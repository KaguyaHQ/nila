defmodule Nila.Gst.Sales.InvoiceValidationTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Sales.{Gstr1, InvoiceValidation}

  test "retained printed IGST drives both comparison values and mismatch checks" do
    for {printed, passed?} <- [{18, true}, {20, false}] do
      invoice =
        invoice(%{
          "printed_tax_totals" => [%{"printed_label" => "IGST", "printed_amount" => printed}]
        })

      assert Nila.Gst.Sales.Values.printed(invoice).tax == printed

      check =
        Enum.find(InvoiceValidation.checks(invoice), &(&1["code"] == "printed_tax_mismatch"))

      assert check["passed"] == passed?
      assert check["operands"]["printed"] == printed

      assert Enum.any?(
               InvoiceValidation.issues([invoice]),
               &(&1["code"] == "printed_tax_mismatch")
             ) == not passed?

      assert Nila.Gst.InvoiceFacts.to_sales_map(Nila.Gst.InvoiceFacts.sales!(invoice))[
               "printed_total_tax"
             ] == nil
    end
  end

  test "money tolerance is decided in exact paise" do
    invoice = invoice(%{}, %{"igst_amount" => 18.50})

    assert Enum.find(InvoiceValidation.checks(invoice), &(&1["code"] == "line_arithmetic"))[
             "passed"
           ]

    invoice = invoice(%{}, %{"igst_amount" => 18.51})

    refute Enum.find(InvoiceValidation.checks(invoice), &(&1["code"] == "line_arithmetic"))[
             "passed"
           ]
  end

  test "missing taxable amounts do not turn an uncalculated tax total into a mismatch" do
    incomplete =
      invoice(
        %{"printed_tax_totals" => [%{"printed_label" => "IGST", "printed_amount" => 18}]},
        %{"taxable_value" => nil, "igst_rate" => nil, "igst_amount" => nil}
      )

    issues = InvoiceValidation.issues([incomplete])
    assert Enum.any?(issues, &(&1["code"] == "missing_taxable_value"))

    refute Enum.any?(
             InvoiceValidation.checks(incomplete),
             &(&1["code"] in ~w(printed_tax_mismatch grand_total_mismatch))
           )

    corrected = put_in(incomplete, ["line_items", Access.at(0), "igst_amount"], 20)

    assert Enum.any?(
             InvoiceValidation.issues([corrected]),
             &(&1["code"] == "printed_tax_mismatch")
           )
  end

  test "tax comparisons use tax inputs independently of taxable amounts" do
    invoice = invoice(%{"printed_total_tax" => 20}, %{"taxable_value" => nil})
    assert Enum.any?(InvoiceValidation.issues([invoice]), &(&1["code"] == "printed_tax_mismatch"))
    assert InvoiceValidation.comparison_totals(invoice) == %{taxable: nil, tax: 18.0, total: nil}
  end

  test "missing tax amounts defer comparisons but explicit zero remains comparable" do
    missing = invoice(%{"printed_total_tax" => 18}, %{"igst_amount" => nil})

    refute Enum.any?(
             InvoiceValidation.checks(missing),
             &(&1["code"] in ~w(line_arithmetic printed_tax_mismatch grand_total_mismatch))
           )

    assert InvoiceValidation.comparison_totals(missing).tax == nil

    zero = put_in(missing, ["line_items", Access.at(0), "igst_amount"], 0)
    assert Enum.any?(InvoiceValidation.issues([zero]), &(&1["code"] == "printed_tax_mismatch"))
    assert InvoiceValidation.comparison_totals(zero).tax == 0
  end

  test "a partial split tax amount does not become a complete tax total" do
    invoice =
      invoice(%{}, %{
        "igst_amount" => nil,
        "igst_rate" => nil,
        "cgst_rate" => 9,
        "cgst_amount" => 9,
        "sgst_rate" => 9,
        "sgst_amount" => nil
      })

    assert InvoiceValidation.comparison_totals(invoice).tax == nil
  end

  test "Gstr1 compatibility API delegates intrinsic validation" do
    invoices = [invoice(), invoice(%{"id" => "source-2"})]

    assert Gstr1.invoice_validation_issues(invoices) == InvoiceValidation.issues(invoices)

    assert Gstr1.duplicate_number_issues(invoices) ==
             InvoiceValidation.duplicate_number_issues(invoices)
  end

  test "bucket rounding uses canonical Decimal rates and paise" do
    lines =
      for index <- 1..3 do
        %{
          "description" => "Small item #{index}",
          "taxable_value" => 0.03,
          "cgst_rate" => if(index == 1, do: "9", else: 9.0),
          "cgst_amount" => if(index < 3, do: 0.01, else: 0),
          "sgst_rate" => if(index == 1, do: Decimal.new("9.00"), else: 9),
          "sgst_amount" => if(index < 3, do: 0.01, else: 0)
        }
      end

    issues =
      invoice(%{"line_items" => lines})
      |> then(&InvoiceValidation.issues([&1]))
      |> Enum.filter(&(&1["code"] == "rounding_variance"))

    assert length(issues) == 2
    assert Enum.all?(issues, &String.contains?(&1["message"], "× 18%"))
  end

  test "bill-to and ship-to disagreement does not invent a place-of-supply issue" do
    invoice =
      Gstr1.normalize_invoice(%{
        "data" => %{
          "invoice_number" => "PHILIPS-1",
          "invoice_date" => "15.07.2026",
          "seller" => %{"gstin" => "33AEWPH4158J1Z3"},
          "buyer" => %{"gstin" => "33AABCP9487A1ZG"},
          "ship_to" => %{"state" => "Telangana", "state_code" => "36"},
          "line_items" => [
            %{
              "description" => "Equipment",
              "printed_taxable_value" => 100,
              "cgst_rate" => 9,
              "cgst_amount" => 9,
              "sgst_rate" => 9,
              "sgst_amount" => 9
            }
          ]
        }
      })

    issues = InvoiceValidation.issues([invoice])

    refute Enum.any?(
             issues,
             &(&1["code"] in ~w(place_of_supply_uncertain tax_treatment_uncertain))
           )

    derived = Gstr1.derive([invoice], %{"gstin" => "33AEWPH4158J1Z3", "fp" => "072026"})

    assert [%{"inv" => [%{"pos" => "33", "itms" => [%{"itm_det" => item}]}]}] =
             derived["b2b"]

    assert item["camt"] == 9
    assert item["samt"] == 9
    assert item["iamt"] == 0
  end

  defp invoice(overrides \\ %{}, line_overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "source-1",
        "document_type" => "invoice",
        "document_status" => "active",
        "supply_type" => "taxable",
        "recipient_registration" => "registered",
        "place_of_supply" => "29",
        "invoice_number" => "INV-1",
        "invoice_date" => ~D[2026-07-15],
        "seller_gstin" => "33AEWPH4158J1Z3",
        "buyer_gstin" => "29AAVCS8021P1ZB",
        "line_items" => [
          Map.merge(
            %{
              "description" => "Support",
              "taxable_value" => 100,
              "igst_rate" => 18,
              "igst_amount" => 18
            },
            line_overrides
          )
        ]
      },
      overrides
    )
  end
end
