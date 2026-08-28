defmodule Nila.Gst.Sales.InvoiceTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Sales.Invoice

  test "owns stable identity and scalar field paths" do
    invoice = %{
      "id" => "d42_invoice_1",
      "invoice_number" => "INV-1",
      "line_items" => [%{"description" => "Old", "taxable_value" => 100.0}]
    }

    assert Invoice.source_id(invoice) == "d42_invoice_1"
    assert Invoice.field_value(invoice, "line_items[0].description") == "Old"

    corrected =
      invoice
      |> Invoice.put_field("invoice_number", "INV-2")
      |> Invoice.put_field("line_items[0].description", "New")

    assert corrected["invoice_number"] == "INV-2"
    assert Invoice.field_value(corrected, "line_items[0].description") == "New"
  end

  test "totals only complete taxable lines and always sums extracted tax" do
    complete = %{
      "line_items" => [
        %{
          "taxable_value" => 100.0,
          "cgst_amount" => 9.0,
          "sgst_amount" => 9.0,
          "igst_amount" => nil
        }
      ]
    }

    assert Invoice.extracted_totals(complete) == %{taxable: 100.0, tax: 18.0}

    assert Invoice.extracted_totals_paise(complete) == %{
             taxable_paise: 10_000,
             tax_paise: 1_800
           }

    assert Invoice.taxable_values_complete?(complete)

    incomplete = put_in(complete, ["line_items", Access.at(0), "taxable_value"], nil)
    assert Invoice.extracted_totals(incomplete) == %{taxable: nil, tax: 18.0}
    assert Invoice.extracted_totals_paise(incomplete) == %{taxable_paise: nil, tax_paise: 1_800}
    refute Invoice.taxable_values_complete?(incomplete)
  end

  test "coerces review text according to the invoice field" do
    assert Invoice.coerce_correction("line_items[0].igst_amount", "12.50") == 12.5
    assert Invoice.coerce_correction("printed_grand_total", "") == nil
    assert Invoice.coerce_correction("invoice_number", "0012") == "0012"
  end
end
