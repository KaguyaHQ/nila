defmodule Nila.Gst.PurchaseBooksTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.PurchaseBooks

  defp artifact(page, data, image \\ nil) do
    %{
      "page" => page,
      "image" => image || "images/page_#{String.pad_leading(to_string(page), 2, "0")}.png",
      "data" => data
    }
  end

  defp line(taxable, opts) do
    %{
      "description" => opts[:description] || "paint",
      "hsn_sac" => opts[:hsn] || "3209",
      "quantity" => 1,
      "taxable_value" => taxable,
      "cgst_amount" => opts[:cgst],
      "sgst_amount" => opts[:sgst],
      "igst_amount" => opts[:igst]
    }
  end

  describe "normalize/1 grouping" do
    test "single-page invoices become separate invoices" do
      result =
        PurchaseBooks.normalize([
          artifact(1, %{
            "is_invoice" => true,
            "invoice_number" => "A100",
            "invoice_date" => "08.10.2025",
            "seller" => %{"name" => "Selvam Paints", "gstin" => "33BREPK0552R1ZK"},
            "buyer" => %{},
            "line_items" => [line(100.0, cgst: 9.0, sgst: 9.0)]
          }),
          artifact(2, %{
            "is_invoice" => true,
            "invoice_number" => "B200",
            "invoice_date" => "09/10/2025",
            "seller" => %{"name" => "Velmurugan", "gstin" => "34AENPK5972Q1ZL"},
            "buyer" => %{},
            "line_items" => [line(200.0, igst: 36.0)]
          })
        ])

      assert [inv1, inv2] = result["invoices"]
      assert inv1["invoice_number"] == "A100"
      assert inv1["pages"] == [1]
      assert inv1["taxable_paise"] == 10_000
      assert inv1["tax_paise"] == %{"cgst" => 900, "sgst" => 900, "igst" => 0}
      assert inv2["invoice_number"] == "B200"
      assert inv2["tax_paise"]["igst"] == 3600
      assert result["skipped_pages"] == []
    end

    test "continuation page folds into previous invoice" do
      result =
        PurchaseBooks.normalize([
          artifact(1, %{
            "is_invoice" => true,
            "invoice_number" => "A024532",
            "invoice_date" => "08/10/2025",
            "seller" => %{"name" => "Selvam Paints", "gstin" => "33BREPK0552R1ZK"},
            "buyer" => %{},
            "line_items" => [line(2980.8, cgst: 268.26, sgst: 268.26)]
          }),
          artifact(2, %{
            "is_invoice" => false,
            "continuation_of_previous" => true,
            "invoice_number" => "A024532",
            "seller" => %{"name" => "Selvam Paints", "gstin" => "33BREPK0552R1ZK"},
            "buyer" => %{},
            "line_items" => [],
            "printed_grand_total" => 3522.0
          })
        ])

      assert [invoice] = result["invoices"]
      assert invoice["pages"] == [1, 2]
      assert length(invoice["images"]) == 2
      assert invoice["printed_total_paise"] == 352_200
      assert result["skipped_pages"] == []
    end

    test "same invoice number and gstin on consecutive pages groups without continuation flag" do
      data = %{
        "is_invoice" => true,
        "invoice_number" => "X1",
        "invoice_date" => "01.10.2025",
        "seller" => %{"name" => "Vendor", "gstin" => "33BREPK0552R1ZK"},
        "buyer" => %{},
        "line_items" => [line(50.0, cgst: 4.5, sgst: 4.5)]
      }

      result = PurchaseBooks.normalize([artifact(1, data), artifact(2, data)])

      assert [invoice] = result["invoices"]
      assert invoice["pages"] == [1, 2]
      assert invoice["taxable_paise"] == 10_000
    end

    test "non-invoice page with nothing on it is skipped with reason" do
      result =
        PurchaseBooks.normalize([
          artifact(1, %{
            "is_invoice" => false,
            "invoice_number" => nil,
            "seller" => %{},
            "buyer" => %{},
            "line_items" => []
          })
        ])

      assert result["invoices"] == []
      assert [%{"page" => 1, "reason" => "not_an_invoice"}] = result["skipped_pages"]
    end
  end

  describe "clean_gstin/1" do
    test "strips separators and validates checksum" do
      assert {:ok, "33AEWPH4158J1Z3"} = PurchaseBooks.clean_gstin("33-AEWPH4158J-1Z3")
    end

    test "tags checksum failures invalid but keeps the value" do
      assert {:invalid, "33AEWPH4158J1Z9"} = PurchaseBooks.clean_gstin("33AEWPH4158J1Z9")
    end

    test "nil and blank are missing" do
      assert {:missing, nil} = PurchaseBooks.clean_gstin(nil)
      assert {:missing, nil} = PurchaseBooks.clean_gstin("  ")
    end
  end

  describe "parse_date/1" do
    test "parses printed formats" do
      assert ~D[2025-10-08] = PurchaseBooks.parse_date("08.10.2025")
      assert ~D[2025-10-08] = PurchaseBooks.parse_date("08/10/2025")
      assert ~D[2025-10-08] = PurchaseBooks.parse_date("8-10-25")
      assert ~D[2025-10-08] = PurchaseBooks.parse_date("Date: 08/10/2025 7:32PM")
    end

    test "garbage is nil" do
      assert PurchaseBooks.parse_date("октябрь") == nil
      assert PurchaseBooks.parse_date("99.99.2025") == nil
      assert PurchaseBooks.parse_date(nil) == nil
    end
  end

  describe "paise/1" do
    test "converts rupee values" do
      assert PurchaseBooks.paise(3522.0) == 352_200
      assert PurchaseBooks.paise(104.74) == 10_474
      assert PurchaseBooks.paise("1,275.00") == 127_500
      assert PurchaseBooks.paise(nil) == 0
    end
  end
end
