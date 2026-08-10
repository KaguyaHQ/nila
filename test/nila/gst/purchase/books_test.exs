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

    test "keeps supplier note face values positive and derives effect from document type" do
      result =
        PurchaseBooks.normalize([
          artifact(1, %{
            "document_type" => "credit_note",
            "invoice_number" => "Credit Note: CN-104",
            "invoice_date" => "15/07/2026",
            "seller" => %{"name" => "Supplier", "gstin" => "29AAVCS8021P1ZB"},
            "line_items" => [line(20_000, igst: 3_600)]
          }),
          artifact(2, %{
            "document_type" => "debit_note",
            "invoice_number" => "Debit Note: DN-105",
            "invoice_date" => "16/07/2026",
            "seller" => %{"name" => "Supplier", "gstin" => "29AAVCS8021P1ZB"},
            "line_items" => [line(10_000, igst: 1_800)]
          })
        ])

      assert [credit, debit] = result["invoices"]
      assert credit["document_type"] == "credit_note"
      assert credit["document_effect"] == -1
      assert credit["invoice_number"] == "CN-104"
      assert credit["taxable_paise"] == 2_000_000
      assert credit["tax_paise"]["igst"] == 360_000

      assert debit["document_type"] == "debit_note"
      assert debit["document_effect"] == 1
      assert debit["invoice_number"] == "DN-105"
      assert debit["taxable_paise"] == 1_000_000
      assert debit["tax_paise"]["igst"] == 180_000
    end

    test "uses document markers when purchase structuring omits the note type" do
      note =
        artifact(1, %{
          "invoice_number" => "CN-104",
          "seller" => %{"name" => "Supplier", "gstin" => "29AAVCS8021P1ZB"},
          "line_items" => [line(20_000, igst: 3_600)]
        })
        |> Map.put("document", %{"credit_note" => true, "debit_note" => false})

      assert %{"invoices" => [%{"document_type" => "credit_note"}]} =
               PurchaseBooks.normalize([note])
    end

    test "tax-inclusive purchase evidence derives taxable paise without changing printed amounts" do
      result =
        PurchaseBooks.normalize([
          artifact(1, %{
            "is_invoice" => true,
            "invoice_number" => "INC-1",
            "invoice_date" => "15/07/2026",
            "seller" => %{"name" => "Supplier", "gstin" => "29AAVCS8021P1ZB"},
            "buyer" => %{},
            "line_items" => [
              %{
                "description" => "Inclusive goods",
                "hsn_sac" => "8471",
                "quantity" => 1,
                "printed_unit_price" => 1_180,
                "printed_line_amount" => 1_180,
                "printed_taxable_value" => nil,
                "line_amount_tax_inclusion" => "inclusive",
                "igst_rate" => 18,
                "igst_amount" => 180
              }
            ]
          })
        ])

      assert [invoice] = result["invoices"]
      assert invoice["taxable_paise"] == 100_000
      assert [line] = invoice["line_items"]
      assert line["unit_price_paise"] == 118_000
      assert line["printed_line_amount_paise"] == 118_000
      assert line["printed_taxable_value_paise"] == nil
      assert line["line_amount_tax_inclusion"] == "inclusive"
    end

    test "materializes exclusive line amounts when the printed subtotal, tax and total reconcile" do
      result =
        PurchaseBooks.normalize([
          artifact(1, %{
            "document_type" => "credit_note",
            "invoice_number" => "CN-NILA-PUR-001",
            "seller" => %{"name" => "Supplier", "gstin" => "29AAVCS8021P1ZB"},
            "line_items" => [
              %{
                "description" => "Controlled supplier credit note",
                "printed_line_amount" => 20_000,
                "printed_taxable_value" => nil,
                "line_amount_tax_inclusion" => "unknown",
                "igst_rate" => 18,
                "igst_amount" => 3_600
              }
            ],
            "printed_subtotal_before_discount" => 20_000,
            "printed_igst" => 3_600,
            "printed_total_tax" => 3_600,
            "printed_grand_total" => 23_600
          })
        ])

      assert [credit] = result["invoices"]
      assert credit["document_type"] == "credit_note"
      assert credit["taxable_paise"] == 2_000_000
      assert credit["tax_paise"]["igst"] == 360_000
      assert credit["total_paise"] == 2_360_000
      assert [line] = credit["line_items"]
      assert line["line_amount_tax_inclusion"] == "exclusive"
      assert line["taxable_paise"] == 2_000_000
      assert line["taxable_value_basis"] == "derived_from_reconciled_invoice_totals"
    end

    test "excludes a taxable total that appeared numerically but lacked a taxable label" do
      page =
        artifact(1, %{
          "document_type" => "credit_note",
          "invoice_number" => "CN-UNGROUNDED",
          "seller" => %{"name" => "Supplier", "gstin" => "29AAVCS8021P1ZB"},
          "line_items" => [
            %{
              "printed_line_amount" => 20_000,
              "printed_taxable_value" => nil,
              "line_amount_tax_inclusion" => "unknown",
              "igst_rate" => 18,
              "igst_amount" => 3_600
            }
          ],
          "printed_subtotal_before_discount" => 20_000,
          "printed_total_taxable" => 20_000,
          "printed_igst" => 3_600,
          "printed_total_tax" => 3_600,
          "printed_grand_total" => 23_600
        })
        |> Map.put("verification", %{
          "failed_checks" => [
            %{"kind" => "grounding", "field" => "printed_total_taxable"}
          ]
        })

      assert %{"invoices" => [credit]} = PurchaseBooks.normalize([page])
      assert credit["ungrounded_fields"] == ["printed_total_taxable"]
      assert credit["printed_taxable_paise"] == nil
      assert credit["taxable_paise"] == 2_000_000
      assert credit["total_paise"] == 2_360_000
    end

    test "does not infer exclusive pricing when the printed totals do not reconcile" do
      result =
        PurchaseBooks.normalize([
          artifact(1, %{
            "invoice_number" => "UNCLEAR",
            "line_items" => [
              %{
                "printed_line_amount" => 20_000,
                "line_amount_tax_inclusion" => "unknown",
                "igst_rate" => 18,
                "igst_amount" => 3_600
              }
            ],
            "printed_subtotal_before_discount" => 20_000,
            "printed_total_tax" => 3_600,
            "printed_grand_total" => 25_000
          })
        ])

      assert [invoice] = result["invoices"]
      assert invoice["taxable_paise"] == 0
      assert [line] = invoice["line_items"]
      assert line["line_amount_tax_inclusion"] == "unknown"
    end

    test "does not book an inclusive gross as taxable when the GST rate is missing" do
      result =
        PurchaseBooks.normalize([
          artifact(1, %{
            "is_invoice" => true,
            "invoice_number" => "INC-NO-RATE",
            "invoice_date" => "15/07/2026",
            "seller" => %{"name" => "Supplier", "gstin" => "29AAVCS8021P1ZB"},
            "buyer" => %{},
            "line_items" => [
              %{
                "description" => "Inclusive goods",
                "printed_line_amount" => 1_180,
                "printed_taxable_value" => nil,
                "line_amount_tax_inclusion" => "inclusive"
              }
            ]
          })
        ])

      assert [invoice] = result["invoices"]
      assert invoice["taxable_paise"] == 0
      assert [line] = invoice["line_items"]
      assert line["printed_line_amount_paise"] == 118_000
      assert line["taxable_paise"] == 0
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
