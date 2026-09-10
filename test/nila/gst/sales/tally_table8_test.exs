defmodule Nila.Gst.Sales.TallyTable8Test do
  use ExUnit.Case, async: true
  alias Nila.Gst.Sales.Gstr1.Readiness, as: Gstr1Readiness
  alias Nila.Gst.Extraction.Sales.Normalizer
  alias Nila.Gst.Sales.Invoice
  alias Nila.Eval.Gstr1Diff
  alias Nila.Gst.Sales.{Gstr1, Workings, Review}
  alias Nila.Gst.Sales.Review.Values
  @root Path.expand("../../../fixtures/gstr1/tally/2026-03", __DIR__)

  setup do
    expected = read("native-gstr1.json")

    %{
      invoices: Enum.map(read("extraction.json")["pages"], &Normalizer.normalize/1),
      expected: expected,
      header: Map.take(expected, ~w(gstin fp))
    }
  end

  test "tax-free printed lines survive missing tax rates and ambiguous inclusion", c do
    assert length(c.invoices) == 12
    assert Enum.all?(c.invoices, &(length(&1["line_items"]) == 1))
    invoice = Enum.at(c.invoices, 8)
    assert hd(invoice["line_items"])["taxable_value"] == 3100
    assert hd(invoice["line_items"])["taxable_value_basis"] == "non_taxable_line_amount"
    assert hd(invoice["line_items"])["printed_taxable_value"] == nil
    assert hd(invoice["line_items"])["line_amount_tax_inclusion"] == "unknown"
    assert Invoice.resolve_line_amounts(invoice) == invoice
    restored = invoice |> Map.put("supply_type", "taxable") |> Invoice.resolve_line_amounts()
    assert hd(restored["line_items"])["taxable_value"] == nil
  end

  test "all four Table 8 categories match native nil, exempt and non-GST amounts", c do
    result = Workings.materialize(c.invoices, read("review.json"), c.header)
    assert result.issues == []
    assert result.silent_errors == []
    assert Enum.all?(result.invoices, &(Gstr1.filing_table(&1) == "nil"))
    assert result.derived["nil"] == c.expected["nil"]
    assert result.derived["b2b"] == []
    assert result.derived["b2cs"] == []
    assert result.derived["cdnur"] == []
    assert Values.filed_totals(result.derived) == Values.filed_totals(c.expected)

    assert Nila.Gst.Filing.Gstr3b.liability_from_gstr1(result.derived) ==
             %{"txval" => 0, "igst" => 0, "cgst" => 0, "sgst" => 0}

    assert Enum.sum(Enum.map(Gstr1.signed_details(result.derived), & &1.detail["txval"])) == 27000
    assert Enum.all?(Review.build(result).all, &(&1.treatment["table"] == "nil"))

    assert Enum.map(
             Gstr1Diff.diff(result.derived, c.expected)["mismatches"],
             &{&1["scope"], &1["field"]}
           ) ==
             List.duplicate({"hsn_b2c", "desc"}, 3)
  end

  test "GST-charged lines cannot be silently filed as exempt", c do
    invoice = c.invoices |> Enum.at(4) |> put_in(["line_items", Access.at(0), "igst_rate"], 18)
    assert Gstr1.filing_table(invoice) == nil

    assert Enum.any?(
             Gstr1Readiness.blocking_issues([invoice]),
             &(&1["code"] == "non_taxable_tax_conflict")
           )
  end

  test "Table 8 amount errors remain visible in the comparison", c do
    changed = put_in(c.expected, ["nil", "inv", Access.at(0), "expt_amt"], 999)

    assert [%{"scope" => "nil", "field" => "expt_amt"}] =
             Gstr1Diff.diff(changed, c.expected)["mismatches"]
  end

  defp read(name), do: @root |> Path.join(name) |> File.read!() |> Jason.decode!()
end
