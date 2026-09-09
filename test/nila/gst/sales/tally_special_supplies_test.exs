defmodule Nila.Gst.Sales.TallySpecialSuppliesTest do
  use ExUnit.Case, async: true

  alias Nila.Eval.Gstr1Diff
  alias Nila.Gst.Sales.{Gstr1, Invoice, Review, Values, Workings}
  alias Nila.Gst.Filing.WinmanGstr1
  @root Path.expand("../../../fixtures/gstr1/tally/2026-06", __DIR__)

  setup do
    expected = read("native-gstr1.json")
    invoices = Enum.map(read("extraction.json")["pages"], &Gstr1.normalize_invoice/1)
    header = Map.take(expected, ~w(gstin fp))

    %{
      expected: expected,
      invoices: invoices,
      header: header,
      result: Workings.materialize(invoices, read("review.json"), header)
    }
  end

  test "native PDFs through production Qwen and one evidence correction match all six return invoices",
       c do
    assert length(c.invoices) == 6
    assert c.result.issues == []
    assert c.result.silent_errors == []

    assert Enum.sort_by(c.result.derived["b2b"], & &1["ctin"]) ==
             Enum.sort_by(c.expected["b2b"], & &1["ctin"])

    assert Enum.sort_by(c.result.derived["exp"], & &1["exp_typ"]) ==
             Enum.sort_by(c.expected["exp"], & &1["exp_typ"])

    assert Values.filed_totals(c.result.derived) == Values.filed_totals(c.expected)
    assert Values.filed_totals(c.result.derived).taxable == 210_000
    assert Values.filed_totals(c.result.derived).tax == 19_800

    # Native Tally groups this manual-number voucher series into one Table 13
    # row. Nila infers six number series; keep that discrepancy visible.
    for mismatch <- Gstr1Diff.diff(c.result.derived, c.expected)["mismatches"] do
      assert mismatch["scope"] == "doc_issue" or
               (mismatch["scope"] in ["hsn", "hsn_b2c"] and
                  mismatch["field"] in ["desc", "user_desc"])
    end
  end

  test "LUT tax printed in a summary is preserved as evidence but not filed", c do
    lut = Enum.filter(c.result.invoices, &Invoice.without_payment?/1)
    assert length(lut) == 2

    for invoice <- lut do
      assert Gstr1.extracted_totals(invoice).tax > 0
      assert Values.filed(invoice, c.result.derived).tax == 0
      assert Values.for_invoice(invoice, c.result.derived).printed_vs_extracted.total == 0
    end

    review = Review.build(c.result)
    assert Enum.count(review.all, &(&1.treatment["table"] == "exp")) == 2
    assert Enum.count(review.all, &(&1.treatment["reverse_charge"] == true)) == 2
  end

  test "a model-confused LUT and RCM combination requires a correction", c do
    unreviewed = Workings.materialize(c.invoices, [], c.header)
    assert Enum.any?(unreviewed.issues, &(&1["code"] == "special_supply_conflict"))
    assert Gstr1.filing_table(Enum.at(c.invoices, 3)) == nil
    assert Enum.at(c.result.invoices, 3)["reverse_charge"] == false
    assert Enum.at(c.invoices, 3)["reverse_charge"] == true
  end

  test "payment ambiguity and unsupported special notes are held out", c do
    sez = Enum.at(c.result.invoices, 2)
    unknown = Map.put(sez, "tax_payment", "unknown")
    assert Gstr1.filing_table(unknown) == nil
    assert Enum.any?(Gstr1.blocking_issues([unknown]), &(&1["code"] == "missing_tax_payment"))
    note = Map.put(sez, "document_type", "credit_note")
    assert Gstr1.filing_table(note) == nil
    assert Enum.any?(Gstr1.blocking_issues([note]), &(&1["code"] == "special_note_unsupported"))
  end

  test "SEZ with payment remains IGST even in the supplier's state", c do
    invoice = Enum.at(c.result.invoices, 2)
    assert String.starts_with?(invoice["buyer_gstin"], "33")
    assert Values.filed(invoice, c.result.derived).igst == 5400
    assert Values.filed(invoice, c.result.derived).cgst == 0
  end

  test "export comparison catches dropped invoices and changed payment treatment", c do
    assert Enum.any?(
             Gstr1Diff.diff(Map.put(c.expected, "exp", []), c.expected)["mismatches"],
             &(&1["scope"] == "export")
           )

    changed = put_in(c.expected, ["exp", Access.at(0), "exp_typ"], "WOPAY")

    assert Enum.any?(
             Gstr1Diff.diff(changed, c.expected)["mismatches"],
             &(&1["field"] == "exp_typ")
           )
  end

  test "Winman's B2B-only workbook includes RCM and explicitly omits SEZ and exports", c do
    assert {:ok, manifest} = WinmanGstr1.export_manifest(c.result)
    assert manifest.included_b2b_invoices == 2
    assert manifest.omitted_documents == 4
    assert Enum.map(manifest.omitted_by_table, &{&1.table, &1.count}) == [{"exp", 2}, {"sez", 2}]
    assert {:ok, bytes} = WinmanGstr1.build(c.result, %{name: "Fixture"}, "2026-06")
    {:ok, entries} = :zip.extract(bytes, [:memory])
    xml = entries |> Map.new() |> Map.fetch!(~c"xl/worksheets/sheet2.xml")
    assert xml =~ "SDK3-RCM-L"
    assert xml =~ ">Yes<"
    refute xml =~ "SDK3-SEZ"
    refute xml =~ "SDK3-EXP"
  end

  test "Excel working includes exports, separates treatments and keeps recipient RCM tax out of invoice value",
       c do
    assert {:ok, bytes} =
             Nila.Gst.Sales.WorkingsXlsx.build(
               c.result,
               %{name: "Fixture", gstin: c.header["gstin"]},
               "2026-06"
             )

    {:ok, entries} = :zip.extract(bytes, [:memory])
    files = Map.new(entries, fn {name, data} -> {List.to_string(name), data} end)

    strings =
      Regex.scan(~r/<t(?:\s[^>]*)?>(.*?)<\/t>/s, files["xl/sharedStrings.xml"],
        capture: :all_but_first
      )
      |> List.flatten()

    sheet = files["xl/worksheets/sheet2.xml"]
    assert Enum.sum(for row <- 5..10, do: cell_number(sheet, "J#{row}")) == 210_000

    assert Enum.sum(
             for row <- 5..10,
                 do:
                   cell_number(sheet, "K#{row}") + cell_number(sheet, "N#{row}") +
                     cell_number(sheet, "Q#{row}")
           ) == 37_800

    refute "Filing taxable" in strings

    sales = files["xl/worksheets/sheet1.xml"]
    assert Enum.sum(for row <- 5..10, do: cell_number(sales, "K#{row}")) == 224_400

    for label <- ["B2B RCM", "SEZ - IGST", "SEZ - LUT/bond", "Export - IGST", "Export - LUT/bond"] do
      assert label in strings
    end

    hsn = files["xl/worksheets/sheet3.xml"]

    for row <- [8, 10] do
      assert Enum.at(strings, trunc(cell_number(hsn, "G#{row}"))) == "LUT/bond"
      assert hsn =~ ~s|IF(G#{row}="Interstate",ROUND(H#{row}*F#{row},2),0)|
    end
  end

  defp cell_number(xml, ref) do
    [_, value] = Regex.run(~r/<c\b[^>]*\br="#{ref}"[^>]*>.*?<v>([^<]+)<\/v>.*?<\/c>/s, xml)
    {number, ""} = Float.parse(value)
    number
  end

  defp read(name), do: @root |> Path.join(name) |> File.read!() |> Jason.decode!()
end
