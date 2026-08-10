defmodule Nila.Gst.Extraction.VerifyTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Extraction.Verify

  defp invoice(overrides) do
    Map.merge(
      %{
        "invoice_number" => "BRZ/26/020",
        "seller" => %{"gstin" => "33AAKCS8613A1ZM"},
        "line_items" => [
          %{"taxable_value" => 40_000.0, "cgst_rate" => 9.0, "sgst_rate" => 9.0},
          %{"taxable_value" => 24_552.0, "cgst_rate" => 9.0, "sgst_rate" => 9.0}
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
    | Item | 40,000.00 |
    | Item | 24,552.00 |
    Taxable 64,552.00  CGST 5,809.68  SGST 5,809.68
    Total tax 11,619.36
    Grand total 76,171.36
    #{extra}
    """
  end

  test "a coherent, fully printed invoice verifies" do
    assert %{status: :verified, flags: []} = Verify.invoice(invoice(%{}), page())
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

    assert %{status: :verified, flags: []} = Verify.invoice(inclusive, text)
  end

  test "a value that appears nowhere on the page is flagged, not reconciled" do
    # The real failure: the model returned 62,552 for a bill printing 64,552, and
    # every downstream check passed because nothing contradicted the invention.
    fabricated = invoice(%{"printed_total_taxable" => 62_552.0})

    assert %{status: :flagged, flags: flags} = Verify.invoice(fabricated, page())
    assert {:value_not_on_page, ["printed_total_taxable"]} in flags
  end

  test "digit-boundary matching stops a number borrowing digits from its neighbour" do
    refute Verify.printed?(552.0, "TOTAL 164552.00")
    assert Verify.printed?(552.0, "TOTAL 552.00")
  end

  test "commas and paise spellings still ground" do
    assert Verify.printed?(64_552.0, String.upcase("taxable 64,552.00"))
    assert Verify.printed?(11_619.36, String.upcase("tax 11,619.36"))
  end

  test "a bill whose own printed total is wrong names the outlier and the coherent subset" do
    # breeze 2026-06, invoice 20: the bill prints TOTAL 2,75,000 while its lines
    # sum to 64,552, its tax is 18% of 64,552 and its grand total is their sum.
    # The bill is wrong; the extraction is right; a retry cannot help.
    inconsistent = invoice(%{"printed_total_taxable" => 275_000.0})
    text = page("TOTAL 2,75,000.00")

    assert %{status: :flagged, flags: flags} = Verify.invoice(inconsistent, text)

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

    assert %{status: :unverifiable} = Verify.invoice(bare, page())
  end

  test "a GSTIN that fails its check digit is flagged" do
    bad = invoice(%{"seller" => %{"gstin" => "33AAKCS8613A1ZQ"}})
    text = String.replace(page(), "33AAKCS8613A1ZM", "33AAKCS8613A1ZQ")

    assert %{status: :flagged, flags: flags} = Verify.invoice(bad, text)
    assert {:invalid_gstin, ["33AAKCS8613A1ZQ"]} in flags
  end

  test "CGST and SGST that disagree fail arithmetic even when both are printed" do
    skewed = invoice(%{"printed_cgst" => 5_000.0, "printed_sgst" => 6_619.36})
    text = page("CGST 5,000.00 SGST 6,619.36")

    assert %{status: :flagged, checks: checks} = Verify.invoice(skewed, text)
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
        "line_items" => [%{"taxable_value" => 841.0, "cgst_rate" => 2.5, "sgst_rate" => 2.5}],
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

      assert %{status: :verified} = Verify.invoice(rcm, text)
    end

    test "the declaration nearly every Tally invoice prints is not a reverse charge" do
      refute Verify.reverse_charge?("Whether tax is payable under reverse charge : No")
      refute Verify.reverse_charge?("Reverse Charge (Y/N): N")

      assert Verify.reverse_charge?(
               "GST payable by the service recipient under the reverse charge mechanism"
             )
    end

    test "the same numbers without a reverse-charge declaration still fail" do
      forward = %{
        "invoice_number" => "X-1",
        "line_items" => [%{"taxable_value" => 841.0}],
        "printed_total_taxable" => 841.0,
        "printed_total_tax" => 42.05,
        "printed_grand_total" => 841.0
      }

      assert %{status: :flagged} =
               Verify.invoice(forward, "Taxable 841.00 Tax 42.05 Total 841.00")
    end
  end

  describe "document markers" do
    test "recognizes a credit-note heading and ignores invoice footer terms" do
      assert Verify.document_markers("| Credit Note-3 |\nCredit Note:03/2024-25")[
               "credit_note"
             ]

      refute Verify.document_markers("TAX INVOICE\nTerms: No credit notes after seven days")[
               "credit_note"
             ]
    end

    test "recognizes a debit-note heading independently" do
      markers = Verify.document_markers("# DEBIT NOTE\nDebit Note No: DN-4")
      assert markers["debit_note"]
      refute markers["credit_note"]
    end
  end

  test "a repaired value is grounded against what the page printed, not the correction" do
    # The repair replaced a scan-damaged GSTIN with its only legal reading; the
    # corrected form is by definition not on the page, and grounding must check
    # the evidence rather than object to the fix.
    repaired = invoice(%{"seller" => %{"gstin" => "32ABSPI4532L1ZG"}})
    text = String.replace(page(), "33AAKCS8613A1ZM", "32ABSP14532L1ZG")

    repairs = [
      %{"field" => "seller.gstin", "from" => "32ABSP14532L1ZG", "to" => "32ABSPI4532L1ZG"}
    ]

    assert %{status: :verified} = Verify.invoice(repaired, text, repairs)
    assert %{status: :flagged} = Verify.invoice(repaired, text)
  end

  describe "derived total tax" do
    test "a total tax that is the sum of its own printed halves grounds" do
      # breeze 2026-06 page 13: the bill prints CGST 289.83 and SGST 289.83 and
      # no combined figure. Reporting 579.66 is a derivation from two grounded
      # values, not an invention, and grounding exists to catch inventions.
      halves =
        invoice(%{
          "printed_cgst" => 289.83,
          "printed_sgst" => 289.83,
          "printed_total_tax" => 579.66,
          "printed_total_taxable" => 3220.34,
          "printed_grand_total" => 3800.0,
          "line_items" => [%{"taxable_value" => 3220.34, "cgst_rate" => 9.0, "sgst_rate" => 9.0}]
        })

      text = """
      TAX INVOICE BRZ/26/020
      GSTIN 33AAKCS8613A1ZM
      Taxable 3,220.34  CGST 289.83  SGST 289.83
      Grand total 3,800.00
      """

      assert %{status: :verified} = Verify.invoice(halves, text)
    end

    test "a total tax matching nothing on the page is still ungrounded" do
      invented =
        invoice(%{
          "printed_cgst" => 289.83,
          "printed_sgst" => 289.83,
          "printed_total_tax" => 999.0
        })

      text = "Taxable 64,552.00 CGST 289.83 SGST 289.83 Grand total 76,171.36"

      assert %{flags: flags} = Verify.invoice(invented, text)
      assert Enum.any?(flags, &match?({:value_not_on_page, _}, &1))
    end

    test "the taxable value is never derivable — it is where fabrication was found" do
      # 62,552 is what the model returned for a bill printing 64,552. No
      # arithmetic on grounded components may excuse it.
      fabricated =
        invoice(%{"printed_total_taxable" => 62_552.0, "printed_grand_total" => 74_171.36})

      assert %{status: :flagged, flags: flags} = Verify.invoice(fabricated, page())
      assert [{:value_not_on_page, ungrounded}] = flags
      assert "printed_total_taxable" in ungrounded
    end
  end
end
