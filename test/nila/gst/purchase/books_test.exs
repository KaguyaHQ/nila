defmodule Nila.Gst.Purchase.BooksTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Purchase.Books, as: PurchaseBooks

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

    test "uses a printed post-discount breakdown only when the complete invoice arithmetic reconciles" do
      result =
        PurchaseBooks.normalize([
          artifact(1, %{
            "is_invoice" => true,
            "invoice_number" => "A024532",
            "invoice_date" => "2025-10-08",
            "seller" => %{"name" => "Selvam Paints", "gstin" => "33BREPK0552R1ZK"},
            "buyer" => %{},
            "line_items" => [line(3497.68, cgst: 0, sgst: 0)],
            "printed_subtotal_before_discount" => 3497.68,
            "printed_discount_amount" => 516.88,
            "printed_total_taxable" => 2980.80,
            "printed_cgst" => 268.26,
            "printed_sgst" => 268.26,
            "printed_igst" => nil,
            "printed_total_tax" => 536.52,
            "printed_additional_charges" => 5.00,
            "printed_rounding_adjustment" => -0.32,
            "printed_grand_total" => 3522.00
          })
        ])

      assert [invoice] = result["invoices"]
      assert invoice["taxable_paise"] == 298_080
      assert invoice["tax_paise"] == %{"cgst" => 26_826, "sgst" => 26_826, "igst" => 0}
      assert invoice["total_paise"] == 352_200
      assert invoice["printed_discount_paise"] == 51_688
      assert invoice["arithmetic_basis"] == "printed_reconciled"
    end

    test "treats an unprinted discount as zero when the complete totals reconcile" do
      result =
        PurchaseBooks.normalize([
          artifact(1, %{
            "is_invoice" => true,
            "invoice_number" => "INV8101",
            "seller" => %{"gstin" => "33AAAFR6942G1ZB"},
            "buyer" => %{},
            "line_items" => [line(2275, cgst: 112.50, sgst: 112.50)],
            "printed_subtotal_before_discount" => 2275,
            "printed_discount_amount" => nil,
            "printed_total_taxable" => 2275,
            "printed_cgst" => 204.75,
            "printed_sgst" => 204.75,
            "printed_total_tax" => 409.50,
            "printed_rounding_adjustment" => 0.50,
            "printed_grand_total" => 2685
          })
        ])

      assert [invoice] = result["invoices"]
      assert invoice["tax_paise"] == %{"cgst" => 20_475, "sgst" => 20_475, "igst" => 0}
      assert invoice["total_paise"] == 268_500
      assert invoice["arithmetic_basis"] == "printed_reconciled"
    end

    test "uses final reconciled values but marks a conflicting subtotal basis" do
      result =
        PurchaseBooks.normalize([
          artifact(1, %{
            "is_invoice" => true,
            "invoice_number" => "RAC2451",
            "seller" => %{"gstin" => "32BQPPA1973C1Z7"},
            "buyer" => %{},
            "line_items" => [line(560.86, igst: 100.96)],
            "printed_subtotal_before_discount" => 50.48,
            "printed_total_taxable" => 280.43,
            "printed_igst" => 50.48,
            "printed_total_tax" => 50.48,
            "printed_rounding_adjustment" => 0.09,
            "printed_grand_total" => 331
          })
        ])

      assert [invoice] = result["invoices"]
      assert invoice["taxable_paise"] == 28_043
      assert invoice["tax_paise"] == %{"cgst" => 0, "sgst" => 0, "igst" => 5_048}
      assert invoice["total_paise"] == 33_100
      assert invoice["arithmetic_basis"] == "printed_final_reconciled"
    end

    test "does not trust an incomplete printed taxable figure" do
      result =
        PurchaseBooks.normalize([
          artifact(1, %{
            "is_invoice" => true,
            "invoice_number" => "A1",
            "seller" => %{"gstin" => "33BREPK0552R1ZK"},
            "buyer" => %{},
            "line_items" => [line(3497.68, cgst: 0, sgst: 0)],
            "printed_total_taxable" => 2980.80,
            "printed_grand_total" => 3522.00
          })
        ])

      assert [invoice] = result["invoices"]
      assert invoice["taxable_paise"] == 349_768
      assert invoice["total_paise"] == 349_768
      assert invoice["printed_total_paise"] == 352_200
      assert invoice["arithmetic_basis"] == "line_items"
    end

    test "does not silently repair a negative structured discount" do
      result =
        PurchaseBooks.normalize([
          artifact(1, %{
            "is_invoice" => true,
            "invoice_number" => "A1",
            "seller" => %{"gstin" => "33BREPK0552R1ZK"},
            "buyer" => %{},
            "line_items" => [line(3497.68, cgst: 0, sgst: 0)],
            "printed_subtotal_before_discount" => 3497.68,
            "printed_discount_amount" => -516.88,
            "printed_total_taxable" => 2980.80,
            "printed_cgst" => 268.26,
            "printed_sgst" => 268.26,
            "printed_total_tax" => 536.52,
            "printed_additional_charges" => 5.00,
            "printed_rounding_adjustment" => -0.32,
            "printed_grand_total" => 3522.00
          })
        ])

      assert [invoice] = result["invoices"]
      assert invoice["taxable_paise"] == 349_768
      assert invoice["arithmetic_basis"] == "line_items"
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
      assert ~D[2025-10-08] = PurchaseBooks.parse_date("2025-10-08")
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

  describe "paise_or_error/1" do
    test "keeps absent and unreadable apart from a real zero" do
      assert PurchaseBooks.paise_or_error(0) == {:ok, 0}
      assert PurchaseBooks.paise_or_error("0.00") == {:ok, 0}
      assert PurchaseBooks.paise_or_error(nil) == :missing
      assert PurchaseBooks.paise_or_error("  ") == :missing
      # The OCR read an S where a 5 was printed. This used to strip the letters
      # and book ₹12 — small enough to look like a cheap item and never be
      # questioned.
      assert PurchaseBooks.paise_or_error("1,2SO.OO") == :unreadable
      assert PurchaseBooks.paise_or_error("n/a") == :unreadable
      assert PurchaseBooks.paise_or_error("-") == :unreadable
      # Parenthesised negatives were read as positive; refusing them is the
      # honest answer until something needs to book a credit note this way.
      assert PurchaseBooks.paise_or_error("(1275.00)") == :unreadable
      assert PurchaseBooks.paise_or_error("1275.00 Cr") == :unreadable
    end

    test "currency marks are noise, not a parse failure" do
      # The dot in "Rs." survived the old character strip, broke Float.parse and
      # booked a real line as zero.
      assert PurchaseBooks.paise_or_error("Rs. 1,275.00") == {:ok, 127_500}
      assert PurchaseBooks.paise_or_error("Rs.1275.00") == {:ok, 127_500}
      assert PurchaseBooks.paise_or_error("INR 1275") == {:ok, 127_500}
      assert PurchaseBooks.paise_or_error("₹1,275.00") == {:ok, 127_500}
      assert PurchaseBooks.paise_or_error("12,75,000.00") == {:ok, 127_500_000}
      assert PurchaseBooks.paise_or_error("1 275.00") == {:ok, 127_500}
    end

    test "paise/1 still folds both to zero for the summing callers" do
      assert PurchaseBooks.paise("n/a") == 0
      assert PurchaseBooks.paise(nil) == 0
    end
  end

  describe "an invoice date that cannot be read" do
    test "keeps the printed text instead of dropping it to nil" do
      %{"invoices" => [invoice]} =
        PurchaseBooks.normalize([
          artifact(1, %{
            "invoice_number" => "A/1",
            "invoice_date" => "13/13/2025",
            "line_items" => [line(1000.0, cgst: 90.0, sgst: 90.0)]
          })
        ])

      assert invoice["invoice_date"] == nil
      assert invoice["unreadable_invoice_date"] == "13/13/2025"
    end

    test "a readable date reports nothing" do
      %{"invoices" => [invoice]} =
        PurchaseBooks.normalize([
          artifact(1, %{
            "invoice_number" => "A/1",
            "invoice_date" => "08/10/2025",
            "line_items" => [line(1000.0, cgst: 90.0, sgst: 90.0)]
          })
        ])

      assert invoice["invoice_date"] == ~D[2025-10-08]
      assert invoice["unreadable_invoice_date"] == nil
    end

    test "a continuation page with an illegible date does not indict a clean invoice" do
      %{"invoices" => [invoice]} =
        PurchaseBooks.normalize([
          artifact(1, %{
            "invoice_number" => "A/1",
            "invoice_date" => "08/10/2025",
            "line_items" => [line(1000.0, cgst: 90.0, sgst: 90.0)]
          }),
          artifact(2, %{
            "continuation_of_previous" => true,
            "invoice_date" => "—",
            "line_items" => [line(500.0, cgst: 45.0, sgst: 45.0)]
          })
        ])

      assert invoice["invoice_date"] == ~D[2025-10-08]
      assert invoice["unreadable_invoice_date"] == nil
    end
  end

  describe "an amount that cannot be read" do
    test "is named rather than silently counted as zero" do
      %{"invoices" => [invoice]} =
        PurchaseBooks.normalize([
          artifact(1, %{
            "invoice_number" => "A/1",
            "invoice_date" => "08/10/2025",
            "line_items" => [
              %{
                "description" => "paint",
                "taxable_value" => "1,2SO.OO",
                "cgst_amount" => 90.0,
                "sgst_amount" => 90.0
              }
            ]
          })
        ])

      assert invoice["unreadable_amounts"] == ["taxable_value"]
      # Still zero in the sums — the invoice has to total to something — but the
      # zero is no longer indistinguishable from one the supplier printed.
      assert invoice["taxable_paise"] == 0
    end

    test "a genuinely absent amount is not an unreadable one" do
      %{"invoices" => [invoice]} =
        PurchaseBooks.normalize([
          artifact(1, %{
            "invoice_number" => "A/1",
            "invoice_date" => "08/10/2025",
            "line_items" => [line(1000.0, cgst: 90.0, sgst: 90.0)]
          })
        ])

      assert invoice["unreadable_amounts"] == nil
    end
  end
end
