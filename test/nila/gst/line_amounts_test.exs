defmodule Nila.Gst.LineAmountsTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.LineAmounts

  test "derives Simple Systems 31 from gross and combined row GST without changing source fields" do
    line = gross_line([tax("GST", 18, 442.8)], 2902.8)
    resolved = Nila.Gst.Sales.Invoice.resolve_line_amount(line)

    assert resolved["taxable_value"] == 2460
    assert resolved["taxable_value_basis"] == "derived_from_gross_less_printed_tax"
    assert resolved["printed_line_amount"] == nil
    assert resolved["printed_taxable_value"] == nil
    assert resolved["printed_line_total"] == 2902.8
    assert resolved["line_amount_tax_inclusion"] == "unknown"
    assert resolved["printed_tax_components"] == line["printed_tax_components"]
    assert resolved["cgst_amount"] == nil
    assert resolved["sgst_amount"] == nil
    assert Nila.Gst.Sales.Invoice.resolve_line_amount(resolved) == resolved

    assert {:ok, facts} = Nila.Gst.InvoiceFacts.from_sales_map(%{"line_items" => [resolved]})
    assert hd(facts.lines).taxable_value_basis == :derived_from_gross_less_printed_tax
    assert facts.taxable_paise == 246_000
  end

  test "subtracts split taxes once even when canonical projections are present" do
    line = gross_line([tax("CGST", 9, 9), tax("SGST", 9, 9)])
    projected = Nila.Gst.TaxComponents.project(%{"line_items" => [line]})
    assert LineAmounts.taxable_value(hd(projected["line_items"])) == 100
    assert LineAmounts.taxable_value(gross_line([tax("IGST@18%", 18, 18)])) == 100
    assert LineAmounts.taxable_value(gross_line([tax("GST", nil, 18)])) == 100
  end

  test "requires complete unambiguous row taxes and consistent rates for gross subtraction" do
    for components <- [
          [],
          [tax("CGST", 9, 9)],
          [tax("CGST", 9, 9), tax("SGST", 9, nil)],
          [tax("GST", 18, nil)],
          [tax("GST", 18, 18), tax("GST", 18, 18)],
          [tax("GST", 18, 18), tax("CGST", 9, 9), tax("SGST", 9, 9)],
          [tax("PGST", 18, 18)],
          [tax("GST", 9, 18)],
          [tax("GST", "unreadable", 18)],
          [tax("GST", nil, -18)],
          [tax("GST", nil, 119)]
        ] do
      assert LineAmounts.taxable_value(gross_line(components)) == nil
    end

    conflicting = gross_line([tax("IGST", 18, 18)]) |> Map.put("igst_amount", 20)
    assert LineAmounts.taxable_value(conflicting) == nil

    assert LineAmounts.taxable_value(
             Map.put(gross_line([tax("GST", 18, 18)]), "printed_line_amount", "unreadable")
           ) == nil

    assert LineAmounts.taxable_value(
             Map.put(gross_line([tax("GST", 18, 18)]), "printed_taxable_value", "unreadable")
           ) == nil

    footer_only = %{"printed_line_total" => 118, "printed_tax_totals" => [tax("IGST", 18, 18)]}
    assert LineAmounts.taxable_value(footer_only) == nil
  end

  test "keeps printed and reviewer taxable values ahead of gross subtraction" do
    line = gross_line([tax("GST", 18, 18)])
    assert LineAmounts.taxable_value(Map.put(line, "printed_taxable_value", 101)) == 101

    corrected = Map.merge(line, %{"taxable_value" => 99, "taxable_value_basis" => "corrected"})
    assert LineAmounts.taxable_value(corrected) == 99
  end

  test "accepts complete canonical item taxes when literal components are unavailable" do
    line = %{"printed_line_total" => 118, "igst_rate" => 18, "igst_amount" => 18}
    assert LineAmounts.taxable_value(line) == 100
    assert LineAmounts.taxable_value(Map.put(line, "printed_tax_components", [])) == nil
    assert LineAmounts.taxable_value(%{"printed_line_total" => 118, "cgst_amount" => 9}) == nil
  end

  defp tax(label, rate, amount),
    do: %{"printed_label" => label, "printed_rate" => rate, "printed_amount" => amount}

  defp gross_line(components, total \\ 118),
    do: %{
      "printed_line_amount" => nil,
      "printed_taxable_value" => nil,
      "printed_line_total" => total,
      "line_amount_tax_inclusion" => "unknown",
      "printed_tax_components" => components
    }

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
