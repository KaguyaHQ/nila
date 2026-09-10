defmodule Nila.Gst.Extraction.InvoiceVerificationTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Extraction.InvoiceVerification

  defp invoice(overrides) do
    Map.merge(
      %{
        "invoice_number" => "BRZ/26/020",
        "seller" => %{"gstin" => "33AAKCS8613A1ZM"},
        "line_items" => [
          %{"printed_taxable_value" => 40_000.0, "cgst_rate" => 9.0, "sgst_rate" => 9.0},
          %{"printed_taxable_value" => 24_552.0, "cgst_rate" => 9.0, "sgst_rate" => 9.0}
        ],
        "printed_total_taxable" => 64_552.0,
        "printed_cgst" => 5_809.68,
        "printed_sgst" => 5_809.68,
        "printed_total_tax" => 11_619.36,
        "printed_grand_total" => 76_171.36
      },
      overrides
    )
  end

  defp page(extra \\ "") do
    """
    TAX INVOICE  BRZ/26/020
    GSTIN 33AAKCS8613A1ZM
    | Item | 40,000.00 | CGST 9% | SGST 9% |
    | Item | 24,552.00 | CGST 9% | SGST 9% |
    Taxable 64,552.00  CGST 5,809.68  SGST 5,809.68
    Total tax 11,619.36
    Grand total 76,171.36
    #{extra}
    """
  end

  test "grand total fallback includes component-only tax without claiming an independent total" do
    data =
      invoice(%{
        "line_items" => [],
        "printed_total_taxable" => 5000,
        "printed_total_tax" => nil,
        "printed_tax_totals" => [%{"printed_label" => "IGST", "printed_amount" => 900}],
        "printed_cgst" => nil,
        "printed_sgst" => nil,
        "printed_igst" => 900,
        "printed_grand_total" => 5900
      })

    result = InvoiceVerification.structured(data)
    assert Enum.any?(result.checks, &(&1.field == "grand_total" and &1.ok?))
    refute Enum.any?(result.checks, &(&1.field == "tax_components_sum"))
  end

  test "a coherent, fully printed invoice verifies" do
    assert %{status: :verified, flags: []} = InvoiceVerification.invoice(invoice(%{}), page())
  end

  test "structured-only checks never claim independent source verification" do
    assert %{status: :unverifiable, flags: [], checks: checks} =
             InvoiceVerification.structured(invoice(%{}))

    assert checks != []
  end

  test "a tax-inclusive line verifies from printed evidence without a taxable total" do
    inclusive = %{
      "invoice_number" => "INV-000005",
      "line_items" => [
        %{
          "printed_unit_price" => 100_000,
          "printed_line_amount" => 100_000,
          "printed_taxable_value" => nil,
          "line_amount_tax_inclusion" => "inclusive",
          "igst_rate" => 18,
          "igst_amount" => 15_254.24
        }
      ],
      "printed_igst" => 15_254.24,
      "printed_total_tax" => 15_254.24,
      "printed_grand_total" => 100_000
    }

    text = """
    TAX INVOICE INV-000005
    Rate 1,00,000.00 IGST 18% 15,254.24 Amount 1,00,000.00
    Sub Total (Tax Inclusive) 1,00,000.00
    Total ₹1,00,000.00
    """

    assert %{status: :verified, flags: []} = InvoiceVerification.invoice(inclusive, text)
  end

  test "a value that appears nowhere on the page is flagged, not reconciled" do
    # The real failure: the model returned 62,552 for a bill printing 64,552, and
    # every downstream check passed because nothing contradicted the invention.
    fabricated = invoice(%{"printed_total_taxable" => 62_552.0})

    assert %{status: :flagged, flags: flags} = InvoiceVerification.invoice(fabricated, page())
    assert {:value_not_on_page, ["printed_total_taxable"]} in flags
  end

  test "digit-boundary matching stops a number borrowing digits from its neighbour" do
    refute InvoiceVerification.printed?(552.0, "TOTAL 164552.00")
    refute InvoiceVerification.printed?(552.0, "TOTAL 552.99")
    assert InvoiceVerification.printed?(552.0, "TOTAL 552.00")
  end

  test "missing row rates use footer tax instead of treating it as zero" do
    result =
      InvoiceVerification.structured(%{
        "line_items" => [%{"printed_taxable_value" => 1000}],
        "printed_total_taxable" => 1000,
        "printed_total_tax" => 180,
        "printed_grand_total" => 1180
      })

    assert Enum.find(result.checks, &(&1.field == "grand_total")).ok?
    assert result.flags == []
  end

  test "zero-rate and missing-rate lines cannot share another line's positive rate" do
    for other <- [%{"igst_rate" => 0}, %{}] do
      result =
        InvoiceVerification.structured(%{
          "line_items" => [
            %{"printed_taxable_value" => 1000, "igst_rate" => 18, "igst_amount" => 180},
            Map.put(other, "printed_taxable_value", 1000)
          ],
          "printed_total_taxable" => 2000,
          "printed_total_tax" => 180,
          "printed_grand_total" => 2180
        })

      refute Enum.any?(result.checks, &(&1.field == "tax_is_rate_times_taxable"))
      assert result.flags == []
    end
  end

  test "an incomplete line sum is not compared with the complete printed total" do
    result =
      InvoiceVerification.structured(%{
        "line_items" => [%{"printed_taxable_value" => 1000}, %{}],
        "printed_total_taxable" => 2000,
        "printed_total_tax" => 360,
        "printed_grand_total" => 2360
      })

    refute Enum.any?(result.checks, &(&1.field == "lines_sum_vs_printed_taxable"))
    assert Enum.find(result.checks, &(&1.field == "grand_total")).ok?
  end

  test "commas and paise spellings still establish source presence" do
    assert InvoiceVerification.printed?(64_552.0, String.upcase("taxable 64,552.00"))
    assert InvoiceVerification.printed?(11_619.36, String.upcase("tax 11,619.36"))
  end

  test "a printed taxable candidate does not require vendor-specific vocabulary" do
    value_column =
      invoice(%{
        "printed_total_taxable" => 64_552.0,
        "line_items" => [
          %{
            "printed_line_amount" => 64_552.0,
            "printed_line_total" => 76_171.36,
            "line_amount_tax_inclusion" => "exclusive",
            "cgst_rate" => 9.0,
            "cgst_amount" => 5_809.68,
            "sgst_rate" => 9.0,
            "sgst_amount" => 5_809.68
          }
        ]
      })

    text = """
    TAX INVOICE BRZ/26/020 GSTIN 33AAKCS8613A1ZM
    | Item | Value | CGST | SGST | Total |
    | Service | 64,552.00 | 9% 5,809.68 | 9% 5,809.68 | 76,171.36 |
    | TOTAL | 64,552.00 | | 11,619.36 | 76,171.36 |
    """

    assert %{status: :verified, flags: []} = InvoiceVerification.invoice(value_column, text)
  end

  test "a bill whose own printed total is wrong names the outlier and the coherent subset" do
    # breeze 2026-06, invoice 20: the bill prints TOTAL 2,75,000 while its lines
    # sum to 64,552, its tax is 18% of 64,552 and its grand total is their sum.
    # The bill is wrong; the extraction is right; a retry cannot help.
    inconsistent = invoice(%{"printed_total_taxable" => 275_000.0})
    text = page("TOTAL 2,75,000.00")

    assert %{status: :flagged, flags: flags} = InvoiceVerification.invoice(inconsistent, text)

    assert [{:internally_inconsistent_bill, detail}] =
             Enum.filter(flags, &match?({:internally_inconsistent_bill, _}, &1))

    assert detail.field == "printed_total_taxable"
    assert detail.printed == 275_000.0
    assert detail.implied == 64_552.0
    assert "line_items" in detail.agreeing
    assert length(detail.agreeing) >= 2
  end

  test "an invoice with no printed totals is unverifiable, never verified" do
    bare = %{"invoice_number" => "BRZ/26/020", "line_items" => []}

    assert %{status: :unverifiable} = InvoiceVerification.invoice(bare, page())
  end

  test "a GSTIN that fails its check digit is flagged" do
    bad = invoice(%{"seller" => %{"gstin" => "33AAKCS8613A1ZQ"}})
    text = String.replace(page(), "33AAKCS8613A1ZM", "33AAKCS8613A1ZQ")

    assert %{status: :flagged, flags: flags} = InvoiceVerification.invoice(bad, text)
    assert {:invalid_gstin, ["33AAKCS8613A1ZQ"]} in flags
  end

  test "CGST and SGST that disagree fail arithmetic even when both are printed" do
    skewed = invoice(%{"printed_cgst" => 5_000.0, "printed_sgst" => 6_619.36})
    text = page("CGST 5,000.00 SGST 6,619.36")

    assert %{status: :flagged, checks: checks} = InvoiceVerification.invoice(skewed, text)
    assert Enum.any?(checks, &(&1.field == "cgst_equals_sgst" and not &1.ok?))
  end

  describe "reverse charge" do
    test "a reverse-charge bill does not add tax to its own total" do
      # Porter consignment note, breeze 2026-06 page 18: taxable 841, tax 42.05,
      # total 841 — the recipient pays the GST, so the supplier's bill excludes
      # it. Freight and legal fees are routinely RCM, so an invariant that always
      # adds tax would flag a whole category of real purchases.
      rcm = %{
        "invoice_number" => "CRN1648270398",
        "line_items" => [
          %{"printed_taxable_value" => 841.0, "cgst_rate" => 2.5, "sgst_rate" => 2.5}
        ],
        "printed_total_taxable" => 841.0,
        "printed_cgst" => 21.02,
        "printed_sgst" => 21.02,
        "printed_total_tax" => 42.05,
        "printed_grand_total" => 841.0
      }

      text = """
      Invoice/ Consignment note  CRN1648270398
      Total Amount 841  Taxable Value 841.00
      CGST (2.5%) 21.02  SGST/UTGST (2.5%) 21.02  Total Tax Amount 42.05
      *GST payable by the service recipient under the reverse charge mechanism
      """

      assert %{status: :verified} = InvoiceVerification.invoice(rcm, text)
    end

    test "the declaration nearly every Tally invoice prints is not a reverse charge" do
      refute InvoiceVerification.reverse_charge?(
               "Whether tax is payable under reverse charge : No"
             )

      refute InvoiceVerification.reverse_charge?("Reverse Charge (Y/N): N")

      assert InvoiceVerification.reverse_charge?(
               "GST payable by the service recipient under the reverse charge mechanism"
             )
    end

    test "the same numbers without a reverse-charge declaration still fail" do
      forward = %{
        "invoice_number" => "X-1",
        "line_items" => [%{"printed_taxable_value" => 841.0}],
        "printed_total_taxable" => 841.0,
        "printed_total_tax" => 42.05,
        "printed_grand_total" => 841.0
      }

      assert %{status: :flagged} =
               InvoiceVerification.invoice(forward, "Taxable 841.00 Tax 42.05 Total 841.00")
    end
  end

  describe "document markers" do
    test "recognizes a credit-note heading and ignores invoice footer terms" do
      assert InvoiceVerification.document_markers("| Credit Note-3 |\nCredit Note:03/2024-25")[
               "credit_note"
             ]

      assert InvoiceVerification.document_markers("**CREDIT NOTE**\n# : CN-NILA-PUR-001")[
               "credit_note"
             ]

      refute InvoiceVerification.document_markers(
               "TAX INVOICE\nTerms: No credit notes after seven days"
             )[
               "credit_note"
             ]
    end

    test "recognizes a debit-note heading independently" do
      markers = InvoiceVerification.document_markers("# DEBIT NOTE\nDebit Note No: DN-4")
      assert markers["debit_note"]
      refute markers["credit_note"]
    end
  end

  test "a repaired value is checked against what the page printed, not the correction" do
    # The repair replaced a scan-damaged GSTIN with its only legal reading; the
    # corrected form is by definition not on the page, and source presence must check
    # the evidence rather than object to the fix.
    repaired = invoice(%{"seller" => %{"gstin" => "32ABSPI4532L1ZG"}})
    text = String.replace(page(), "33AAKCS8613A1ZM", "32ABSP14532L1ZG")

    repairs = [
      %{"field" => "seller.gstin", "from" => "32ABSP14532L1ZG", "to" => "32ABSPI4532L1ZG"}
    ]

    assert %{status: :verified} = InvoiceVerification.invoice(repaired, text, repairs)
    assert %{status: :flagged} = InvoiceVerification.invoice(repaired, text)
  end

  describe "printed versus derived totals" do
    test "an unprinted total tax cannot masquerade as printed evidence" do
      halves =
        invoice(%{
          "printed_cgst" => 289.83,
          "printed_sgst" => 289.83,
          "printed_total_tax" => 579.66,
          "printed_total_taxable" => 3220.34,
          "printed_grand_total" => 3800.0,
          "line_items" => [
            %{"printed_taxable_value" => 3220.34, "cgst_rate" => 9.0, "sgst_rate" => 9.0}
          ]
        })

      text = """
      TAX INVOICE BRZ/26/020
      GSTIN 33AAKCS8613A1ZM
      Taxable 3,220.34  CGST 9% 289.83  SGST 9% 289.83
      Grand total 3,800.00
      """

      assert %{status: :flagged, flags: flags} = InvoiceVerification.invoice(halves, text)
      assert {:value_not_on_page, ["printed_total_tax"]} in flags
    end

    test "a printed Value total is source-present without a magic taxable label" do
      extracted = %{
        "printed_subtotal_before_discount" => 20_000,
        "printed_total_taxable" => 20_000,
        "printed_igst" => 3_600,
        "printed_total_tax" => 3_600,
        "printed_grand_total" => 23_600,
        "line_items" => [
          %{
            "printed_line_amount" => 20_000,
            "line_amount_tax_inclusion" => "exclusive",
            "igst_rate" => 18,
            "igst_amount" => 3_600
          }
        ]
      }

      text = "Sub Total 20,000.00 IGST18 (18%) 3,600.00 Total 23,600.00"

      assert %{status: :verified, flags: []} = InvoiceVerification.invoice(extracted, text)
    end

    test "a total tax matching nothing on the page is absent" do
      invented =
        invoice(%{
          "printed_cgst" => 289.83,
          "printed_sgst" => 289.83,
          "printed_total_tax" => 999.0
        })

      text = "Taxable 64,552.00 CGST 289.83 SGST 289.83 Grand total 76,171.36"

      assert %{flags: flags} = InvoiceVerification.invoice(invented, text)
      assert Enum.any?(flags, &match?({:value_not_on_page, _}, &1))
    end

    test "an absent taxable candidate is never excused by arithmetic" do
      # 62,552 is what the model returned for a bill printing 64,552. No
      # arithmetic on source-present components may excuse it.
      fabricated =
        invoice(%{"printed_total_taxable" => 62_552.0, "printed_grand_total" => 74_171.36})

      assert %{status: :flagged, flags: flags} = InvoiceVerification.invoice(fabricated, page())
      assert [{:value_not_on_page, absent}] = flags
      assert "printed_total_taxable" in absent
    end
  end
end
