defmodule Nila.Gst.Sales.InvoiceValidationTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Sales.{Gstr1, InvoiceValidation}

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
              "taxable_value" => 100,
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
