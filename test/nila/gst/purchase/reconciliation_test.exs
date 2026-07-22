defmodule Nila.Gst.Purchase.ReconciliationTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Purchase.Reconciliation, as: Recon

  @gstin_a "33AAACS1234A1Z9"
  @gstin_b "29AAACV5678B1Z5"

  defp books(attrs) do
    Map.merge(
      %{
        "id" => "page_01",
        "vendor_name" => "Sharma Steels",
        "vendor_gstin" => @gstin_a,
        "invoice_number" => "INV-001",
        "invoice_date" => ~D[2025-04-15],
        "taxable_paise" => 1_000_000,
        "tax_paise" => %{"cgst" => 90_000, "sgst" => 90_000, "igst" => 0},
        "total_paise" => 1_180_000
      },
      attrs
    )
  end

  defp g2b(attrs) do
    Map.merge(
      %{
        "vendor_gstin" => @gstin_a,
        "vendor_name" => "SHARMA STEELS",
        "invoice_number" => "INV-001",
        "invoice_date" => ~D[2025-04-15],
        "taxable_paise" => 1_000_000,
        "tax_paise" => %{"cgst" => 90_000, "sgst" => 90_000, "igst" => 0},
        "total_paise" => 1_180_000,
        "itc_available" => true,
        "itc_reason" => nil,
        "reverse_charge" => false,
        "pos" => "33"
      },
      attrs
    )
  end

  defp empty_buckets_except(result, keep) do
    for {bucket, rows} <- result, bucket not in keep do
      assert rows == [], "expected #{bucket} to be empty, got: #{inspect(rows)}"
    end
  end

  describe "exact ladder rung" do
    test "GSTIN + exact invoice number + values in tolerance is matched" do
      result = Recon.reconcile([books(%{})], [g2b(%{})])

      assert [row] = result["matched"]
      assert row["match_basis"] == ["gstin", "invoice_number", "value"]
      assert row["deltas"]["taxable"] == 0
      empty_buckets_except(result, ["matched"])
    end

    test "invoice number matches after trim/case/whitespace normalization" do
      result =
        Recon.reconcile(
          [books(%{"invoice_number" => "  inv-001 "})],
          [g2b(%{"invoice_number" => "INV-001"})]
        )

      assert [_] = result["matched"]
    end

    test "poke: 100 paise value drift stays matched inside default tolerance" do
      result = Recon.reconcile([books(%{"taxable_paise" => 1_000_100})], [g2b(%{})])

      assert [row] = result["matched"]
      assert row["deltas"]["taxable"] == 100
    end

    test "poke: 500 paise drift lands value_mismatch, still a confident pairing" do
      result = Recon.reconcile([books(%{"taxable_paise" => 1_000_500})], [g2b(%{})])

      assert [row] = result["value_mismatch"]
      assert row["match_basis"] == ["gstin", "invoice_number"]
      assert row["deltas"]["taxable"] == 500
      empty_buckets_except(result, ["value_mismatch"])
    end

    test "tolerance is opts-tunable" do
      result =
        Recon.reconcile([books(%{"taxable_paise" => 1_000_500})], [g2b(%{})],
          tolerance_paise: 1_000
        )

      assert [_] = result["matched"]
    end
  end

  describe "relaxed invoice-number rung" do
    test "separator/leading-zero/FY-suffix noise matches with date and value corroboration" do
      result =
        Recon.reconcile(
          [books(%{"invoice_number" => "INV-001/2025-26"})],
          [g2b(%{"invoice_number" => "INV 1"})]
        )

      assert [row] = result["matched"]
      assert "relaxed_invoice_number" in row["match_basis"]
    end

    test "relaxed match with only one corroborator goes to needs_human" do
      result =
        Recon.reconcile(
          [books(%{"invoice_number" => "INV/001", "invoice_date" => ~D[2025-06-30]})],
          [g2b(%{"invoice_number" => "INV-001"})]
        )

      assert [row] = result["needs_human"]
      assert row["reason"]["code"] == "relaxed_match_weak_corroboration"
      empty_buckets_except(result, ["needs_human"])
    end
  end

  describe "invoice-number disagreement" do
    test "poke: transposed invoice-number digits go to needs_human, never matched" do
      result =
        Recon.reconcile(
          [books(%{"invoice_number" => "INV-1243"})],
          [g2b(%{"invoice_number" => "INV-1234"})]
        )

      assert [row] = result["needs_human"]
      assert row["reason"]["code"] == "invoice_number_mismatch"
      assert result["matched"] == []
    end
  end

  describe "ambiguity guard" do
    test "poke: same vendor, two invoices, same value, garbled numbers land needs_human" do
      books_invoices = [
        books(%{"id" => "page_03", "invoice_number" => "GARBLED@#1"}),
        books(%{"id" => "page_04", "invoice_number" => "SMUDGE**2"})
      ]

      g2b_invoices = [
        g2b(%{"invoice_number" => "SS/101"}),
        g2b(%{"invoice_number" => "SS/102"})
      ]

      result = Recon.reconcile(books_invoices, g2b_invoices)

      assert result["matched"] == []
      assert result["value_mismatch"] == []
      assert length(result["needs_human"]) == 2

      for row <- result["needs_human"] do
        assert row["reason"]["code"] in ["ambiguous_matches", "invoice_number_mismatch"]
        assert length(row["candidates"]) >= 1
      end
    end

    test "duplicate invoice numbers on the 2B side are never auto-paired" do
      result =
        Recon.reconcile(
          [books(%{})],
          [g2b(%{}), g2b(%{"total_paise" => 999_900, "taxable_paise" => 999_000})]
        )

      assert result["matched"] == []
      assert [row] = result["needs_human"]
      assert row["reason"]["code"] == "ambiguous_matches"
    end
  end

  describe "fuzzy vendor-name rung (missing GSTIN)" do
    test "poke: nil GSTIN resolves via fuzzy name + exact invoice number + value" do
      result =
        Recon.reconcile(
          [books(%{"vendor_gstin" => nil, "vendor_name" => "Sharma Steel"})],
          [g2b(%{"vendor_name" => "SHARMA STEELS"})]
        )

      assert [row] = result["matched"]
      assert row["match_basis"] == ["fuzzy_vendor_name", "invoice_number", "value"]
    end

    test "poke: vendor name off by one letter still pairs only with full corroboration" do
      result =
        Recon.reconcile(
          [books(%{"vendor_gstin" => nil, "vendor_name" => "Sharna Steels"})],
          [g2b(%{"vendor_name" => "SHARMA STEELS"})]
        )

      assert [row] = result["matched"]
      assert "fuzzy_vendor_name" in row["match_basis"]
    end

    test "fuzzy name without exact invoice number is needs_human, never matched" do
      result =
        Recon.reconcile(
          [books(%{"vendor_gstin" => nil, "invoice_number" => "OTHER-99"})],
          [g2b(%{})]
        )

      assert result["matched"] == []
      assert [row] = result["needs_human"]
      assert row["reason"]["code"] == "fuzzy_name_weak_corroboration"
    end

    # Regression: a handwritten cash bill (Maheswari & Co) whose vendor GSTIN was
    # mis-extracted to the buyer's, invoice number missed, and whose hand-totaled
    # tax drifts ~3 paise from the portal, while the taxable ties exactly. It must
    # surface its 2B counterpart as a review candidate, never a false "missing".
    test "taxable ties exactly but tax drifts: candidate for review, not missing" do
      maheswari_books =
        books(%{
          "vendor_gstin" => "33BPBK1081A1Z0",
          "vendor_name" => "Maheswari & Co",
          "invoice_number" => nil,
          "taxable_paise" => 238_100,
          "tax_paise" => %{"cgst" => 24_400, "sgst" => 24_400, "igst" => 0},
          "total_paise" => 286_900
        })

      maheswari_2b =
        g2b(%{
          "vendor_gstin" => "33APZPP6215J1ZB",
          "vendor_name" => "MAHESWARI AND CO",
          "invoice_number" => "125",
          "taxable_paise" => 238_100,
          "tax_paise" => %{"cgst" => 24_259, "sgst" => 24_259, "igst" => 0},
          "total_paise" => 286_818
        })

      result = Recon.reconcile([maheswari_books], [maheswari_2b])

      assert result["in_books_not_2b"] == []
      assert [row] = result["needs_human"]
      assert row["reason"]["code"] == "fuzzy_name_weak_corroboration"
      assert [candidate] = row["candidates"]
      assert candidate["vendor_name"] == "MAHESWARI AND CO"
    end

    test "invalid GSTIN is treated as missing and routed through the fuzzy rung" do
      result =
        Recon.reconcile(
          [books(%{"vendor_gstin" => "33AAACS1234A1Z0"})],
          [g2b(%{})]
        )

      assert [row] = result["matched"]
      assert "fuzzy_vendor_name" in row["match_basis"]
    end

    test "an unrelated vendor name never pairs" do
      result =
        Recon.reconcile(
          [books(%{"vendor_gstin" => nil, "vendor_name" => "Totally Different Traders"})],
          [g2b(%{})]
        )

      assert result["matched"] == []
      assert [_] = result["in_books_not_2b"]
      assert [_] = result["in_2b_not_books"]
    end
  end

  describe "residuals" do
    test "poke: books invoice absent from 2B is flagged honestly, not asserted missing" do
      result = Recon.reconcile([books(%{})], [])

      assert [row] = result["in_books_not_2b"]
      assert row["reason"]["code"] == "no_confident_gstr2b_match"
      assert row["next_action"] =~ "automatically"
      assert row["next_action"] =~ "Sharma Steels"
      assert row["next_action"] =~ "GSTR-1"
    end

    test "poke: 2B invoice absent from books drafts a client checklist item" do
      result = Recon.reconcile([], [g2b(%{})])

      assert [row] = result["in_2b_not_books"]
      assert row["reason"]["code"] == "missing_in_books"
      assert row["next_action"] =~ "GSTR-2B shows invoice INV-001 from vendor SHARMA STEELS"
      assert row["next_action"] =~ "do you have this bill?"
    end

    test "different vendors never cross-match" do
      result =
        Recon.reconcile(
          [books(%{})],
          [g2b(%{"vendor_gstin" => @gstin_b, "vendor_name" => "Verma Traders"})]
        )

      assert result["matched"] == []
      assert [_] = result["in_books_not_2b"]
      assert [_] = result["in_2b_not_books"]
    end
  end

  describe "field passthrough" do
    test "poke: reverse-charge and ITC-unavailable flags survive into the matched row" do
      result =
        Recon.reconcile(
          [books(%{})],
          [g2b(%{"reverse_charge" => true, "itc_available" => false, "itc_reason" => "P"})]
        )

      assert [row] = result["matched"]
      assert row["gstr2b"]["reverse_charge"] == true
      assert row["gstr2b"]["itc_available"] == false
      assert row["gstr2b"]["itc_reason"] == "P"
      refute Map.has_key?(row["gstr2b"], "_ix")
    end
  end
end
