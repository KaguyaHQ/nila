defmodule Nila.Gst.Sales.InvoiceTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Sales.Invoice

  test "document readers preserve defaults and explicit blank values" do
    assert Invoice.document_type(%{}) == "invoice"
    assert Invoice.document_status(%{}) == "active"
    assert Invoice.supply_type(%{}) == "taxable"
    assert Invoice.supply_type(%{"document" => %{"export" => true}}) == "export"
    assert Invoice.document_type(%{"document_type" => ""}) == ""
    assert Invoice.document_status(%{"document_status" => ""}) == ""
    assert Invoice.supply_type(%{"supply_type" => "", "document" => %{"export" => true}}) == ""
    assert Invoice.recipient_registration(%{"buyer_gstin" => "   "}) == "unknown"
    assert Invoice.recipient_registration(%{"buyer_gstin" => "33AEWPH4158J1Z3"}) == "registered"

    assert Invoice.recipient_registration(%{"recipient_registration" => "", "buyer_gstin" => "x"}) ==
             ""
  end

  test "document readers consume typed facts without replacing their evidence" do
    raw = %{
      "document_type" => "credit_note",
      "invoice_number" => "CN-1",
      "invoice_date" => "2026-08-10",
      "buyer_gstin" => "33AEWPH4158J1Z3",
      "document_status" => "cancelled",
      "supply_type" => "sez",
      "line_items" => []
    }

    facts = Nila.Gst.InvoiceFacts.sales!(raw)
    assert Invoice.document_type(facts) == "credit_note"
    assert Invoice.document_number(facts) == "CN-1"
    assert Invoice.document_date(facts) == ~D[2026-08-10]
    assert Invoice.document_effect(facts) == -1
    assert Invoice.document_status(facts) == "cancelled"
    assert Invoice.supply_type(facts) == "sez"
    assert Invoice.recipient_registration(facts) == "registered"
  end

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
      |> Invoice.apply_correction("invoice_number", "INV-2")
      |> Invoice.apply_correction("line_items[0].description", "New")

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

  test "explicit taxable corrections survive later printed amount corrections" do
    invoice = %{
      "line_items" => [
        %{
          "printed_line_amount" => 118.0,
          "igst_rate" => 18.0,
          "line_amount_tax_inclusion" => "inclusive"
        }
      ]
    }

    corrected =
      invoice
      |> Invoice.apply_correction("line_items[0].taxable_value", 95.0)
      |> Invoice.apply_correction("line_items[0].printed_line_amount", 236.0)
      |> Invoice.resolve_line_amounts()

    [line] = corrected["line_items"]
    assert line["taxable_value"] == 95.0
    assert line["taxable_value_basis"] == "corrected"
    assert line["printed_line_amount"] == 236.0
    assert line["printed_taxable_value"] == nil
  end

  test "coerces review text according to the invoice field" do
    assert Invoice.coerce_correction("line_items[0].igst_amount", "12.50") == 12.5
    assert Invoice.coerce_correction("line_items[0].taxable_value", "1,275.50") == 1275.5
    assert Invoice.coerce_correction("line_items[0].taxable_value", "1,2SO.OO") == "1,2SO.OO"
    assert Invoice.coerce_correction("printed_grand_total", "") == nil
    assert Invoice.coerce_correction("invoice_number", "0012") == "0012"
  end
end
