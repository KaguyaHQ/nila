defmodule Nila.Gst.Extraction.LineAmountsTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Extraction.LineAmounts

  describe "discard_redundant_printed_taxable/1" do
    test "keeps distinct printed values within the arithmetic tolerance" do
      line = %{
        "printed_line_amount" => 100,
        "printed_taxable_value" => 100.02,
        "printed_line_total" => 118,
        "igst_rate" => 18,
        "igst_amount" => 18
      }

      assert {^line, nil} = LineAmounts.discard_redundant_printed_taxable(line)
      assert LineAmounts.taxable_value(line) == 100.02
    end

    test "drops a duplicate only when row arithmetic independently proves exclusive pricing" do
      line = %{
        "printed_line_amount" => 20_500,
        "printed_line_total" => 24_190,
        "printed_taxable_value" => 20_500,
        "line_amount_tax_inclusion" => "exclusive",
        "cgst_rate" => 9,
        "cgst_amount" => 1_845,
        "sgst_rate" => 9,
        "sgst_amount" => 1_845
      }

      assert {cleaned, repair} = LineAmounts.discard_redundant_printed_taxable(line)
      assert cleaned["printed_taxable_value"] == nil
      assert repair["from"] == 20_500
      assert repair["basis"] == "redundant_with_arithmetically_exclusive_line_amount"
    end

    test "keeps equal candidates when arithmetic cannot establish their relationship" do
      line = %{
        "printed_line_amount" => 20_500,
        "printed_taxable_value" => 20_500,
        "line_amount_tax_inclusion" => "exclusive"
      }

      assert {^line, nil} = LineAmounts.discard_redundant_printed_taxable(line)
    end
  end

  test "keeps printed unit, line and taxable amounts as separate evidence" do
    amounts =
      LineAmounts.normalize(%{
        "printed_unit_price" => 118,
        "printed_line_amount" => 1_180,
        "printed_taxable_value" => 1_000,
        "line_amount_tax_inclusion" => "inclusive",
        "igst_rate" => 18
      })

    assert amounts.printed_unit_price == 118
    assert amounts.printed_line_amount == 1_180
    assert amounts.printed_taxable_value == 1_000
    assert amounts.taxable_value == 1_000
    assert amounts.taxable_value_basis == "printed_taxable_value"
  end

  test "retains failed checks without rejecting an inclusive candidate" do
    amounts =
      LineAmounts.normalize(%{
        "printed_line_amount" => 118,
        "printed_line_total" => 118,
        "line_amount_tax_inclusion" => "inclusive",
        "igst_rate" => 18,
        "igst_amount" => 18
      })

    assert amounts.taxable_value == 100
    assert amounts.line_amount_tax_inclusion == "inclusive"
    assert amounts.line_amount_tax_inclusion_basis == "model_candidate"
    assert [total, rate] = amounts.line_amount_tax_inclusion_evidence

    assert total == %{
             "basis" => "line_amount_plus_tax_equals_total",
             "passed" => false,
             "left" => 136.0,
             "right" => 118.0
           }

    assert rate == %{
             "basis" => "line_amount_times_rate_equals_tax",
             "passed" => false,
             "left" => 21.24,
             "right" => 18.0
           }
  end

  test "retains failed arithmetic for exclusive and unknown candidates too" do
    for candidate <- ["exclusive", "unknown"] do
      amounts =
        LineAmounts.normalize(%{
          "printed_line_amount" => 100,
          "printed_line_total" => 150,
          "line_amount_tax_inclusion" => candidate,
          "igst_rate" => 18,
          "igst_amount" => 30
        })

      assert amounts.line_amount_tax_inclusion == candidate
      assert length(amounts.line_amount_tax_inclusion_evidence) == 2
      assert Enum.all?(amounts.line_amount_tax_inclusion_evidence, &(&1["passed"] == false))
    end
  end

  test "zero tax at a positive rate does not prove exclusive pricing" do
    for candidate <- ["unknown", "inclusive", "exclusive"] do
      amounts =
        LineAmounts.normalize(%{
          "printed_line_amount" => 0,
          "printed_line_total" => 0,
          "line_amount_tax_inclusion" => candidate,
          "igst_rate" => 18,
          "igst_amount" => 0
        })

      assert amounts.line_amount_tax_inclusion == candidate
      assert amounts.line_amount_tax_inclusion_evidence == []
      assert amounts.taxable_value == if(candidate == "unknown", do: nil, else: 0)
    end
  end

  test "a stored unknown candidate is preserved when the current inclusion changes" do
    for basis <- [nil, "model_candidate", "corrected"] do
      amounts =
        LineAmounts.normalize(%{
          "printed_line_amount" => 118,
          "line_amount_tax_inclusion_candidate" => "unknown",
          "line_amount_tax_inclusion" => "inclusive",
          "line_amount_tax_inclusion_basis" => basis,
          "igst_rate" => 18
        })

      assert amounts.line_amount_tax_inclusion_candidate == "unknown"

      if basis == "corrected" do
        assert amounts.line_amount_tax_inclusion == "inclusive"
        assert amounts.taxable_value == 100
      else
        assert amounts.line_amount_tax_inclusion == "unknown"
        assert amounts.taxable_value == nil
      end
    end
  end

  test "reviewed inclusion overrides arithmetic and survives another resolution" do
    line = %{
      "printed_line_amount" => 118,
      "printed_line_total" => 139.24,
      "line_amount_tax_inclusion" => "inclusive",
      "line_amount_tax_inclusion_basis" => "corrected",
      "igst_rate" => 18,
      "igst_amount" => 21.24
    }

    amounts = LineAmounts.normalize(line)
    assert amounts.taxable_value == 100
    assert amounts.line_amount_tax_inclusion_basis == "corrected"
    assert amounts.line_amount_tax_inclusion_evidence == ["reviewer_correction"]

    stored = Map.new(amounts, fn {key, value} -> {Atom.to_string(key), value} end)
    assert LineAmounts.normalize(Map.merge(line, stored)) == amounts
  end

  test "old amount fields cannot supply printed evidence or inclusion" do
    amounts =
      LineAmounts.normalize(%{
        "unit_price" => 118,
        "tax_inclusive_value" => 118,
        "taxable_value" => 100,
        "tax_inclusive" => true,
        "igst_rate" => 18
      })

    assert amounts.printed_unit_price == nil
    assert amounts.printed_line_amount == nil
    assert amounts.printed_taxable_value == nil
    assert amounts.taxable_value == nil
    assert amounts.line_amount_tax_inclusion == "unknown"
  end

  test "derives taxable value from an inclusive printed line amount" do
    amounts =
      LineAmounts.normalize(%{
        "printed_unit_price" => 100_000,
        "printed_line_amount" => 100_000,
        "printed_taxable_value" => nil,
        "line_amount_tax_inclusion" => "inclusive",
        "igst_rate" => 18
      })

    assert amounts.taxable_value == 84_745.76
    assert amounts.taxable_value_basis == "derived_from_inclusive_line_amount"
  end

  test "uses an exclusive printed line amount when no taxable column is printed" do
    amounts =
      LineAmounts.normalize(%{
        "printed_line_amount" => 10_000,
        "printed_taxable_value" => nil,
        "line_amount_tax_inclusion" => "exclusive",
        "cgst_rate" => 9,
        "sgst_rate" => 9
      })

    assert amounts.taxable_value == 10_000
    assert amounts.taxable_value_basis == "printed_exclusive_line_amount"
  end

  test "preserves a reviewed taxable correction across re-normalization" do
    amounts =
      LineAmounts.normalize(%{
        "printed_line_amount" => 1_180,
        "printed_taxable_value" => nil,
        "line_amount_tax_inclusion" => "inclusive",
        "taxable_value" => 950,
        "taxable_value_basis" => "corrected",
        "igst_rate" => 18
      })

    assert amounts.printed_taxable_value == nil
    assert amounts.taxable_value == 950
    assert amounts.taxable_value_basis == "corrected"
  end

  test "does not invent taxable value when the amount basis is unknown" do
    amounts =
      LineAmounts.normalize(%{
        "printed_line_amount" => 10_000,
        "printed_taxable_value" => nil,
        "line_amount_tax_inclusion" => "unknown",
        "igst_rate" => 18
      })

    assert amounts.taxable_value == nil
    assert amounts.taxable_value_basis == nil
  end

  test "proves an unknown Value column exclusive from rate and extracted tax" do
    amounts =
      LineAmounts.normalize(%{
        "printed_line_amount" => 21_500,
        "printed_taxable_value" => nil,
        "line_amount_tax_inclusion" => "unknown",
        "igst_rate" => 18,
        "igst_amount" => 3_870
      })

    assert amounts.line_amount_tax_inclusion_candidate == "unknown"
    assert amounts.line_amount_tax_inclusion == "exclusive"
    assert amounts.line_amount_tax_inclusion_basis == "line_amount_times_rate_equals_tax"
    assert amounts.taxable_value == 21_500
    assert amounts.taxable_value_basis == "line_amount_times_rate_equals_tax"
  end

  test "uses both same-row equations when Value plus tax equals Total" do
    amounts =
      LineAmounts.normalize(%{
        "printed_line_amount" => 21_500,
        "printed_line_total" => 25_370,
        "line_amount_tax_inclusion" => "unknown",
        "igst_rate" => 18,
        "igst_amount" => 3_870
      })

    assert amounts.line_amount_tax_inclusion == "exclusive"

    assert Enum.map(amounts.line_amount_tax_inclusion_evidence, & &1["basis"]) == [
             "line_amount_plus_tax_equals_total",
             "line_amount_times_rate_equals_tax"
           ]

    assert Enum.all?(amounts.line_amount_tax_inclusion_evidence, & &1["passed"])
  end

  test "arithmetic overrides and records a disagreeing inclusive candidate" do
    amounts =
      LineAmounts.normalize(%{
        "printed_line_amount" => 10_000,
        "printed_line_total" => 11_800,
        "line_amount_tax_inclusion" => "inclusive",
        "igst_rate" => 18,
        "igst_amount" => 1_800
      })

    assert amounts.line_amount_tax_inclusion == "exclusive"
    assert amounts.taxable_value == 10_000

    assert amounts.line_amount_tax_inclusion_disagreement == %{
             "candidate" => "inclusive",
             "resolved" => "exclusive"
           }
  end

  test "conflicting printed equations stay unresolved" do
    amounts =
      LineAmounts.normalize(%{
        "printed_line_amount" => 10_000,
        "printed_line_total" => 12_000,
        "line_amount_tax_inclusion" => "exclusive",
        "igst_rate" => 18,
        "igst_amount" => 1_800
      })

    assert amounts.line_amount_tax_inclusion == "unknown"
    assert amounts.line_amount_tax_inclusion_basis == "arithmetic_conflict"
    assert amounts.taxable_value == nil
  end

  test "zero-rate and zero-tax evidence remains a real zero without pretending to prove inclusion" do
    amounts =
      LineAmounts.normalize(%{
        "printed_line_amount" => 0,
        "printed_line_total" => 0,
        "line_amount_tax_inclusion" => "exclusive",
        "igst_rate" => 0,
        "igst_amount" => 0
      })

    assert amounts.line_amount_tax_inclusion == "exclusive"
    assert amounts.taxable_value == 0
  end
end
