defmodule Nila.Gst.Extraction.LineAmountsTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Extraction.LineAmounts

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
