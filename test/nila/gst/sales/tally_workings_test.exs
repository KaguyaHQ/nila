defmodule Nila.Gst.Sales.TallyWorkingsTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Extraction.Sales.Normalizer
  alias Nila.Eval.Gstr1Diff
  alias Nila.Gst.Sales.{Gstr1, Workings}

  @fixtures Path.expand("../../../fixtures/gstr1/tally/2026-01", __DIR__)

  setup do
    extraction = read_json("extraction.json")
    expected = read_json("native-gstr1.json")

    %{
      extraction: extraction,
      invoices: Enum.map(extraction["pages"], &Normalizer.normalize/1),
      expected: expected,
      header: Map.take(expected, ["gstin", "fp"])
    }
  end

  test "cached extraction references the registered private corpus packet" do
    manifest = read_json("manifest.json")
    document = Nila.EvalCorpus.document!(manifest["corpus_document"])

    assert document["sha256"] == manifest["source_sha256"]
    assert document["pages"] == 8

    assert File.read!(document["ground_truth"]) ==
             File.read!(Path.join(@fixtures, "native-gstr1.json"))

    refute File.exists?(Path.join(@fixtures, "sales-packet.pdf"))
  end

  test "native PDFs retain all eight documents and expose missing facts for review", context do
    assert context.extraction["unaccounted_pages"] == []
    assert length(context.invoices) == 8
    workings = Workings.materialize(context.invoices, [], context.header)

    assert Enum.map(workings.invoices, &{&1["invoice_number"], &1["document_type"]}) == [
             {"NW-001", "invoice"},
             {"NW-002", "invoice"},
             {"NW-003", "invoice"},
             {"NW-004", "invoice"},
             {"NW-005", "invoice"},
             {"NW-006", "invoice"},
             {"NW-CN-001", "credit_note"},
             {"NW-DN-001", "debit_note"}
           ]

    assert Enum.all?(workings.invoices, &(&1["invoice_date"] == ~D[2026-01-15]))

    assert Enum.map(workings.issues, &{&1["invoice"], &1["code"]}) == [
             {"NW-001", "missing_place_of_supply"},
             {"NW-002", "missing_place_of_supply"},
             {"NW-003", "missing_place_of_supply"},
             {"NW-004", "missing_place_of_supply"},
             {"NW-005", "missing_place_of_supply"}
           ]

    assert get_in(List.last(workings.invoices), ["line_items", Access.at(0), "hsn_sac"]) ==
             "998719"

    refute Workings.reviewable?(workings.issues)
    assert workings.derived["b2cs"] == []
    assert workings.derived["b2cl"] == []
  end

  test "reviewed B2C boundaries and registered notes reproduce native Tally amounts", context do
    workings = Workings.materialize(context.invoices, read_json("review.json"), context.header)

    assert workings.silent_errors == []
    assert workings.issues == []
    assert Workings.reviewable?(workings.issues)

    assert Enum.map(workings.invoices, &{&1["invoice_number"], Gstr1.filing_table(&1)}) == [
             {"NW-001", "b2cs"},
             {"NW-002", "b2cs"},
             {"NW-003", "b2cs"},
             {"NW-004", "b2cl"},
             {"NW-005", "b2cs"},
             {"NW-006", "b2b"},
             {"NW-CN-001", "cdnr"},
             {"NW-DN-001", "cdnr"}
           ]

    # Compare the untouched native return, including HSN and document series.
    # Tally's master description is not printed on these PDFs. Keep the two
    # text differences visible; no financial mismatch is allowed.
    diff = Gstr1Diff.diff(workings.derived, context.expected)

    assert Enum.map(diff["mismatches"], &{&1["scope"], &1["field"]}) |> Enum.sort() ==
             [{"hsn_b2c", "desc"}, {"hsn_b2c", "user_desc"}]

    [hsn] = workings.derived["hsn"]["hsn_b2b"]
    assert hsn["txval"] == 19_000.0
    assert hsn["iamt"] == 3_420.0

    # Reviewing does not overwrite the source evidence.
    assert hd(workings.printed_invoices)["place_of_supply"] == nil
    assert hd(workings.invoices)["place_of_supply"] == "33"
  end

  defp read_json(name), do: @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()
end
