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
