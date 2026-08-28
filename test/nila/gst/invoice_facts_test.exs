defmodule Nila.Gst.InvoiceFactsTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.InvoiceFacts
  alias Nila.Gst.Purchase.Reconciliation
  alias Nila.Gst.Sales.InvoiceValidation

  test "canonicalizes normalized sales facts to paise and Date values" do
    projection = %{
      "id" => "dump_1_invoice_1",
      "document_type" => "invoice",
      "invoice_number" => " INV-1 ",
      "invoice_date" => "2026-08-28",
      "seller_name" => "Supplier",
      "seller_gstin" => " 29aavcs8021p1zb ",
      "buyer_name" => "Buyer",
      "line_items" => [
        %{
          "description" => "Services",
          "quantity" => "2.50",
          "taxable_value" => 1_000.25,
          "taxable_value_basis" => "printed_taxable_value",
          "line_amount_tax_inclusion" => "exclusive",
          "cgst_rate" => "9",
          "cgst_amount" => 90.02,
          "sgst_rate" => 9.0,
          "sgst_amount" => 90.03,
          "igst_amount" => nil
        }
      ],
      "printed_total_taxable" => 1_000.25,
      "printed_total_tax" => 180.05,
      "printed_grand_total" => 1_180.30
    }

    assert {:ok, facts} = InvoiceFacts.from_sales_map(projection)
    assert facts.origin == :sales
    assert facts.number == "INV-1"
    assert facts.date == ~D[2026-08-28]
    assert facts.issuer.gstin == "29AAVCS8021P1ZB"
    assert facts.taxable_paise == 100_025
    assert facts.tax_paise == %{cgst: 9_002, sgst: 9_003, igst: 0}
    assert facts.total_paise == 118_030
    assert facts.printed_total_paise == 118_030
    assert [line] = facts.lines
    assert line.quantity == Decimal.new("2.50")
    assert line.cgst_rate == Decimal.new("9")
    assert line.sgst_rate == Decimal.from_float(9.0)
    assert line.taxable_value_basis == :printed_taxable_value
    assert line.line_amount_tax_inclusion == :exclusive

    sales_projection = InvoiceFacts.to_sales_map(facts)
    assert sales_projection["seller_gstin"] == "29AAVCS8021P1ZB"
    assert sales_projection["invoice_date"] == ~D[2026-08-28]
    assert get_in(sales_projection, ["line_items", Access.at(0), "quantity"]) == 2.5
    assert get_in(sales_projection, ["line_items", Access.at(0), "cgst_rate"]) == 9

    assert get_in(sales_projection, ["line_items", Access.at(0), "taxable_value_basis"]) ==
             "printed_taxable_value"

    assert get_in(sales_projection, ["line_items", Access.at(0), "taxable_value"]) == 1_000.25
  end

  test "keeps unreadable dates as evidence instead of treating them as dates" do
    assert {:ok, facts} =
             InvoiceFacts.from_sales_map(%{
               "invoice_date" => "Invoice Dt.",
               "line_items" => []
             })

    assert facts.date == nil
    assert facts.unreadable_date == "Invoice Dt."
  end

  test "validates normalized purchase facts without reinterpreting paise as rupees" do
    projection = %{
      "id" => "inv_01",
      "document_type" => "invoice",
      "invoice_number" => "P-1",
      "invoice_date" => ~D[2026-08-28],
      "vendor_name" => "Supplier",
      "vendor_gstin" => "29AAVCS8021P1ZB",
      "line_items" => [
        %{
          "description" => "Goods",
          "taxable_paise" => 100_025,
          "tax_paise" => %{"cgst" => 9_002, "sgst" => 9_003, "igst" => 0}
        }
      ],
      "taxable_paise" => 100_025,
      "tax_paise" => %{"cgst" => 9_002, "sgst" => 9_003, "igst" => 0},
      "total_paise" => 118_030
    }

    assert {:ok, facts} = InvoiceFacts.from_purchase_map(projection)
    assert facts.origin == :purchase
    assert facts.taxable_paise == 100_025
    assert facts.lines |> hd() |> Map.fetch!(:taxable_paise) == 100_025
    assert InvoiceFacts.to_purchase_map(facts)["total_paise"] == projection["total_paise"]
  end

  test "rejects stage and unit confusion at domain boundaries" do
    purchase_projection = %{
      "line_items" => [],
      "taxable_paise" => 100,
      "tax_paise" => %{"cgst" => 0, "sgst" => 0, "igst" => 0},
      "total_paise" => 100
    }

    assert {:error, :purchase_projection_passed_as_sales_invoice} =
             InvoiceFacts.from_sales_map(purchase_projection)

    assert {:error, :purchase_money_projection_is_incomplete} =
             InvoiceFacts.from_purchase_map(%{"line_items" => []})

    assert {:error, {:line, 0, {"taxable_paise", :must_be_integer_paise}}} =
             InvoiceFacts.from_purchase_map(%{
               "line_items" => [
                 %{
                   "taxable_paise" => 100.0,
                   "tax_paise" => %{"cgst" => 0, "sgst" => 0, "igst" => 0}
                 }
               ],
               "taxable_paise" => 100,
               "tax_paise" => %{"cgst" => 0, "sgst" => 0, "igst" => 0},
               "total_paise" => 100
             })
  end

  test "validation and reconciliation engines enforce the canonical boundary" do
    purchase_projection = %{
      "line_items" => [],
      "taxable_paise" => 100,
      "tax_paise" => %{"cgst" => 0, "sgst" => 0, "igst" => 0},
      "total_paise" => 100
    }

    assert_raise ArgumentError, ~r/purchase_projection_passed_as_sales_invoice/, fn ->
      InvoiceValidation.checks(purchase_projection)
    end

    assert_raise ArgumentError, ~r/must_be_integer_paise/, fn ->
      Reconciliation.reconcile(
        [
          %{purchase_projection | "taxable_paise" => 100.0}
        ],
        []
      )
    end
  end

  test "rejects values outside the canonical decimal and enum contracts" do
    assert {:error, {:line, 0, {"quantity", :unreadable_decimal}}} =
             InvoiceFacts.from_sales_map(%{
               "line_items" => [%{"quantity" => "two"}]
             })

    assert {:error, {:line, 0, {:unknown_line_amount_tax_inclusion, "approximately_exclusive"}}} =
             InvoiceFacts.from_sales_map(%{
               "line_items" => [
                 %{"line_amount_tax_inclusion" => "approximately_exclusive"}
               ]
             })

    assert {:error, {:line, 0, {:unknown_taxable_value_basis, "guessed"}}} =
             InvoiceFacts.from_sales_map(%{
               "line_items" => [%{"taxable_value_basis" => "guessed"}]
             })
  end
end
