defmodule NilaWeb.Gst.SalesIssuePresentationTest do
  use ExUnit.Case, async: true

  alias NilaWeb.Gst.SalesIssuePresentation

  test "register reasons stay short and name the right party without exposing field codes" do
    assert SalesIssuePresentation.register_reason(%{"code" => "missing_taxable_value"}) ==
             "Taxable amount missing"

    assert SalesIssuePresentation.register_reason(%{
             "code" => "invalid_gstin",
             "fields" => ["seller_gstin"]
           }) == "Seller GSTIN invalid"

    assert SalesIssuePresentation.register_reason(%{
             "code" => "invalid_gstin",
             "fields" => ["buyer_gstin"]
           }) == "Buyer GSTIN invalid"

    assert SalesIssuePresentation.register_reason(%{
             "code" => "new_issue",
             "message" => "internal_field: {}"
           }) == "Check invoice details"
  end

  @invoice %{
    "invoice_number" => "INV-1",
    "seller_gstin" => "33AEWPH4158J1Z3",
    "printed_total_taxable" => 31_000.0,
    "printed_total_tax" => 5_580.0,
    "printed_grand_total" => 36_580.0,
    "line_items" => [
      %{
        "description" => "Service",
        "hsn_sac" => "998719",
        "taxable_value" => 31_000.0,
        "cgst_rate" => 9.0,
        "cgst_amount" => 2_790.0,
        "sgst_rate" => 9.0,
        "sgst_amount" => 2_790.0
      }
    ]
  }

  test "missing tax amounts point the reviewer to the affected lines" do
    presentation =
      SalesIssuePresentation.for_invoice(@invoice, [
        %{"code" => "missing_tax_amount", "lines" => [2]}
      ])

    assert [%{topic: "tax amounts", target: :lines, lines: [2]}] = presentation.items
    assert presentation.summary == "A required GST amount is missing from invoice lines."
  end

  test "does not surface place-of-supply tax inference in the sales-bill workbench" do
    issue = %{
      "code" => "tax_split_mismatch",
      "seller_state" => "33",
      "place_of_supply" => "36",
      "tax_heads" => ["cgst", "sgst"]
    }

    presentation = SalesIssuePresentation.for_invoice(@invoice, [issue])

    assert presentation.items == []
    assert presentation.details == []
  end

  test "does not present mixed tax heads as a place-of-supply mismatch" do
    issue = %{
      "code" => "mixed_tax_heads",
      "tax_heads" => ["igst", "cgst", "sgst"],
      "igst" => 180.0,
      "split_tax" => 180.0
    }

    presentation = SalesIssuePresentation.for_invoice(@invoice, [issue])

    assert presentation.summary ==
             "Invoice uses both IGST and CGST/SGST; one tax treatment must be corrected."

    assert presentation.details == ["Invoice carries ₹180.00 IGST and ₹180.00 CGST/SGST."]
  end

  test "keeps source-level tax arithmetic checks while ignoring inferred treatment" do
    issues = [
      %{
        "code" => "tax_treatment_uncertain",
        "seller_state" => "33",
        "place_of_supply" => "29",
        "tax_heads" => ["sgst"],
        "suggested_tax_treatment" => "igst"
      },
      %{"code" => "lopsided_tax_split", "lines" => [1, 2, 3, 4]},
      %{"code" => "bucket_tax_mismatch"},
      %{"code" => "bucket_tax_mismatch"}
    ]

    presentation = SalesIssuePresentation.for_invoice(@invoice, issues)

    assert presentation.summary == "Tax calculations need review."
    assert [%{topic: "tax calculations"}] = presentation.items
    refute Enum.any?(presentation.items, &("tax_treatment_uncertain" in &1.codes))
  end

  test "keeps an independent arithmetic issue after ignoring inferred treatment" do
    issues = [
      %{
        "code" => "tax_treatment_uncertain",
        "seller_state" => "33",
        "place_of_supply" => "29",
        "tax_heads" => ["sgst"],
        "suggested_tax_treatment" => "igst"
      },
      %{"code" => "lopsided_tax_split", "lines" => [1]},
      %{"code" => "bucket_tax_mismatch"},
      %{"code" => "line_arithmetic", "lines" => [2]}
    ]

    presentation = SalesIssuePresentation.for_invoice(@invoice, issues)

    assert Enum.any?(presentation.items, &("line_arithmetic" in &1.codes))
  end

  test "renders printed totals from issue operands without consulting the invoice" do
    issue = %{
      "code" => "printed_taxable_mismatch",
      "operands" => %{"printed" => 205_130.0, "derived" => 6_486_030.0}
    }

    presentation =
      @invoice
      |> Map.put("printed_total_taxable", 1.0)
      |> Map.put("line_items", [])
      |> SalesIssuePresentation.for_invoice([issue])

    assert presentation.details == [
             "Printed taxable is ₹2,05,130.00; extracted lines total ₹64,86,030.00."
           ]
  end

  test "renders collapsed grand-total evidence carried by a component issue" do
    issue = %{
      "code" => "printed_tax_mismatch",
      "operands" => %{"printed" => 36_923.4, "derived" => 18_804.67},
      "grand_total_operands" => %{"printed" => 242_053.0, "derived" => 6_504_834.67}
    }

    presentation = SalesIssuePresentation.for_invoice(@invoice, [issue])

    assert presentation.details == [
             "Printed tax is ₹36,923.40; extracted lines total ₹18,804.67. Printed invoice total is ₹2,42,053.00; extracted lines total ₹65,04,834.67."
           ]
  end

  test "composes every issue family instead of hiding later blockers" do
    issues = [
      %{
        "code" => "tax_split_mismatch",
        "seller_state" => "33",
        "place_of_supply" => "36",
        "tax_heads" => ["cgst", "sgst"]
      },
      %{
        "code" => "printed_tax_mismatch",
        "operands" => %{"printed" => 5_580.0, "derived" => 5_500.0}
      },
      %{"code" => "missing_hsn_sac", "lines" => [1, 2]},
      %{"code" => "cess_unsupported", "lines" => [2], "hsn_codes" => ["24039910"]}
    ]

    presentation = SalesIssuePresentation.for_invoice(@invoice, issues)

    assert presentation.summary =~ "Unsupported voucher treatment"
    assert presentation.summary =~ "invoice totals"
    assert presentation.summary =~ "HSN/SAC"
    assert length(presentation.details) == 3
    assert Enum.any?(presentation.details, &String.contains?(&1, "compensation cess"))
    assert Enum.any?(presentation.details, &String.contains?(&1, "missing on 2 lines"))
  end

  test "identifies which GSTIN failed" do
    seller = SalesIssuePresentation.for_invoice(@invoice, [invalid_gstin(["seller_gstin"])])
    buyer = SalesIssuePresentation.for_invoice(@invoice, [invalid_gstin(["buyer_gstin"])])

    assert seller.summary == "Seller GSTIN needs correction."
    assert buyer.summary == "Buyer GSTIN needs correction."
  end

  test "keeps HSN validity checks in sales" do
    presentation =
      SalesIssuePresentation.for_invoice(@invoice, [
        %{"code" => "invalid_hsn_sac", "hsn_codes" => ["8415"], "lines" => [1]}
      ])

    assert presentation.summary == "Some HSN/SAC codes are not in the active GST directory."
    assert presentation.details == ["HSN/SAC: 8415. Lines: 1."]
  end

  test "unknown gating codes use neutral review wording" do
    presentation =
      SalesIssuePresentation.for_invoice(@invoice, [%{"code" => "future_required_check"}])

    assert presentation.summary == "Invoice needs review before Tally."
    refute presentation.summary =~ "correction"
  end

  test "does not let ignored POS validation hide a real Tally export failure" do
    issues = [
      %{"code" => "invalid_place_of_supply", "fields" => ["place_of_supply"]},
      %{"code" => "tally_export_failed"}
    ]

    presentation = SalesIssuePresentation.for_invoice(@invoice, issues)

    assert Enum.any?(presentation.items, &("tally_export_failed" in &1.codes))
    refute Enum.any?(presentation.items, &("invalid_place_of_supply" in &1.codes))
  end

  test "keeps a sole Tally export failure as one global decision card" do
    presentation =
      SalesIssuePresentation.for_invoice(@invoice, [%{"code" => "tally_export_failed"}])

    assert [item] = presentation.items
    assert item.target == :global
    assert item.summary == "Nila could not prepare this invoice as a Tally voucher."
  end

  defp invalid_gstin(fields), do: %{"code" => "invalid_gstin", "fields" => fields}
end
