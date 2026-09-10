defmodule Nila.Gst.Sales.TallyUnregisteredNotesTest do
  use ExUnit.Case, async: true
  alias Nila.Gst.Sales.Gstr1.Readiness, as: Gstr1Readiness
  alias Nila.Gst.Extraction.Sales.Normalizer
  alias Nila.Eval.Gstr1Diff
  alias Nila.Gst.Sales.{Gstr1, Workings}
  alias Nila.Gst.Sales.Review.Values
  @root Path.expand("../../../fixtures/gstr1/tally/2026-02", __DIR__)

  setup do
    expected = read("native-gstr1.json")

    %{
      invoices: Enum.map(read("extraction.json")["pages"], &Normalizer.normalize/1),
      expected: expected,
      header: Map.take(expected, ~w(gstin fp))
    }
  end

  test "unknown original sale category stays reviewable instead of using the note value", c do
    source = Enum.at(c.invoices, 2) |> Map.put("place_of_supply", "29")
    assert source["printed_grand_total"] == 2360
    assert Gstr1.filing_table(source) == nil

    assert Enum.any?(
             Gstr1Readiness.blocking_issues([source]),
             &(&1["code"] == "missing_original_sale_category")
           )

    assert Gstr1.filing_table(Map.put(source, "original_sale_category", "b2cl")) == "cdnur"
    assert Gstr1.filing_table(Map.put(source, "original_sale_category", "b2cs")) == "b2cs"
    assert Gstr1.filing_table(Map.put(source, "place_of_supply", "33")) == "b2cs"
  end

  test "reviewed native notes reproduce B2CS netting, CDNUR, HSN and document counts", c do
    result = Workings.materialize(c.invoices, read("review.json"), c.header)
    assert result.issues == []
    assert result.silent_errors == []
    assert Enum.map(result.invoices, &Gstr1.filing_table/1) == ~w(b2cs b2cs cdnur b2cs b2cs cdnur)
    diff = Gstr1Diff.diff(result.derived, c.expected)

    assert Enum.map(diff["mismatches"], &{&1["scope"], &1["field"]}) |> Enum.sort() ==
             [{"hsn_b2c", "desc"}, {"hsn_b2c", "user_desc"}]

    assert Values.filed_totals(result.derived) == Values.filed_totals(c.expected)

    assert Nila.Gst.Filing.Gstr3b.interstate_unregistered_from_gstr1(result.derived) ==
             [%{"pos" => "29", "txval" => -200_000, "igst" => -36000}]

    [credit, debit] = result.derived["cdnur"]
    assert credit["val"] == 2360
    assert debit["val"] == 1180
    assert Enum.sum(Enum.map(Gstr1.signed_details(result.derived), & &1.detail["txval"])) == -3000
  end

  test "CDNUR financial mismatches cannot disappear from the eval", c do
    changed =
      put_in(c.expected, ["cdnur", Access.at(0), "itms", Access.at(0), "itm_det", "iamt"], 999)

    assert [%{"scope" => "cdnur_item", "field" => "iamt"}] =
             Gstr1Diff.diff(changed, c.expected)["mismatches"]
  end

  defp read(name), do: @root |> Path.join(name) |> File.read!() |> Jason.decode!()
end
