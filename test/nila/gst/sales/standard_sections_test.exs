defmodule Nila.Gst.Sales.StandardSectionsTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Sales.{Excel.StandardSections, Excel.ReturnReport, ReturnSources, Gstr1}

  @gstin "33AEWPH4158J1Z3"
  @headers %{
    "A" => "GSTIN/UIN of Recipient",
    "B" => "Receiver Name",
    "C" => "Invoice Number",
    "D" => "Invoice date",
    "E" => "Invoice Value",
    "F" => "Place Of Supply",
    "G" => "Reverse Charge",
    "I" => "Invoice Type",
    "K" => "Rate",
    "L" => "Taxable Value",
    "M" => "Cess Amount"
  }

  defp sheet(name, rows), do: %{name: name, hidden?: false, rows: rows}
  defp row(number, cells), do: %{row: number, cells: cells}

  test "groups repeated B2B rate rows without counting an overview sheet" do
    b2b =
      sheet("b2b", [
        row(4, @headers),
        row(5, %{
          "A" => "33AAACR7926B1ZP",
          "B" => "Buyer",
          "C" => "A1",
          "D" => "01-Aug-2026",
          "E" => "118",
          "F" => "33-Tamil Nadu",
          "G" => "N",
          "I" => "Regular B2B",
          "K" => "18",
          "L" => "50",
          "M" => "0"
        }),
        row(6, %{
          "A" => "33AAACR7926B1ZP",
          "B" => "Buyer",
          "C" => "A1",
          "D" => "01-Aug-2026",
          "E" => "118",
          "F" => "33-Tamil Nadu",
          "G" => "N",
          "I" => "Regular B2B",
          "K" => "18",
          "L" => "50",
          "M" => "0"
        })
      ])

    overview = sheet("gstr1", [row(1, %{"A" => "Printed sales overview"})])
    client = %{gstin: @gstin}
    assert {:ok, report} = StandardSections.parse(%{sheets: [overview, b2b]}, client, "2026-08")
    assert length(report["rows"]) == 2
    assert [invoice] = ReturnReport.invoices(report, client)
    assert invoice["source_sheet"] == "b2b"
    assert invoice["source_rows"] == [5, 6]
    assert length(invoice["line_items"]) == 2

    projection = Gstr1.project([invoice], Gstr1.production_header(@gstin, "2026-08"))

    {projection, issues, _} =
      ReturnSources.apply(projection, [invoice], [
        Map.merge(report, %{"dump_id" => 1, "filename" => "sample.xlsx"})
      ])

    assert [%{"target" => "return_report:hsn_missing:1:hsn_b2b"}] = issues
    assert [%{"inv" => [%{"itms" => items}]}] = projection.derived["b2b"]
    assert Enum.sum(Enum.map(items, & &1["itm_det"]["txval"])) == 100.0
    assert projection.derived["hsn"]["hsn_b2b"] == []
  end

  test "rejects a month mismatch in invoice rows" do
    b2b =
      sheet("B2B", [
        row(1, @headers),
        row(2, %{
          "A" => "33AAACR7926B1ZP",
          "C" => "A1",
          "D" => "01-Jul-2026",
          "E" => "118",
          "F" => "33-Tamil Nadu",
          "K" => "18",
          "L" => "100"
        })
      ])

    assert {:error, message} =
             StandardSections.parse(%{sheets: [b2b]}, %{gstin: @gstin}, "2026-08")

    assert message =~ "outside the selected GST month"
  end

  test "finds a titled B2B table after columns move and retains physical evidence" do
    moved = %{
      "A" => "M",
      "B" => "C",
      "C" => "K",
      "D" => "A",
      "E" => "H",
      "F" => "D",
      "G" => "F",
      "I" => "G",
      "K" => "B",
      "L" => "E",
      "M" => "J"
    }

    move = fn cells -> Map.new(cells, fn {column, value} -> {moved[column], value} end) end

    b2b =
      sheet("B2B", [
        row(1, %{"A" => "August sales"}),
        row(7, move.(@headers)),
        row(
          8,
          move.(%{
            "A" => "33AAACR7926B1ZP",
            "B" => "Buyer",
            "C" => "A1",
            "D" => "01-Aug-2026",
            "E" => "118",
            "F" => "33-Tamil Nadu",
            "G" => "N",
            "I" => "Regular B2B",
            "K" => "18",
            "L" => "100",
            "M" => "0"
          })
        )
      ])

    assert {:ok, %{"rows" => [entry]}} =
             StandardSections.parse(%{sheets: [b2b]}, %{gstin: @gstin}, "2026-08")

    assert entry["row"] == 8
    assert entry["table_plan"] == %{"id" => "standard_sections.b2b", "version" => 1}
    assert entry["columns"]["number"] == "K"
    assert entry["columns"]["rate"] == "B"
    assert entry["cells"]["K"] == "A1"
    assert entry["values"]["txval"] == 100.0
  end

  test "rejects conflicting repeated invoice values instead of taking the first" do
    base = %{
      "A" => "33AAACR7926B1ZP",
      "C" => "A1",
      "D" => "01-Aug-2026",
      "E" => "118",
      "F" => "33-Tamil Nadu",
      "K" => "18",
      "L" => "100"
    }

    b2b = sheet("B2B", [row(1, @headers), row(2, base), row(3, %{base | "E" => "119"})])

    assert {:error, message} =
             StandardSections.parse(%{sheets: [b2b]}, %{gstin: @gstin}, "2026-08")

    assert message =~ "Conflicting value across rows 2, 3"
  end

  test "same invoice number with changed buyer or date is a conflict" do
    base = %{
      "A" => "33AAACR7926B1ZP",
      "B" => "Buyer",
      "C" => "A1",
      "D" => "01-Aug-2026",
      "E" => "118",
      "F" => "33-Tamil Nadu",
      "K" => "18",
      "L" => "100"
    }

    for {field, changed, expected} <- [
          {"A", "33BBBBB1234B1ZP", "buyer_gstin"},
          {"D", "02-Aug-2026", "date"}
        ] do
      b2b = sheet("B2B", [row(1, @headers), row(2, base), row(3, Map.put(base, field, changed))])

      assert {:error, message} =
               StandardSections.parse(%{sheets: [b2b]}, %{gstin: @gstin}, "2026-08")

      assert message =~ "Conflicting #{expected} across rows 2, 3"
    end
  end

  test "same note number with changed original sale category is a conflict" do
    header = %{
      "A" => "UR Type",
      "B" => "Note Number",
      "C" => "Note Date",
      "D" => "Note Type",
      "E" => "Place Of Supply",
      "F" => "Note Value",
      "H" => "Rate",
      "I" => "Taxable Value"
    }

    base = %{
      "A" => "B2CL",
      "B" => "N1",
      "C" => "04-Aug-2026",
      "D" => "C",
      "E" => "33-Tamil Nadu",
      "F" => "105",
      "H" => "5",
      "I" => "100"
    }

    notes = sheet("CDNUR", [row(1, header), row(2, base), row(3, %{base | "A" => "B2CS"})])

    assert {:error, message} =
             StandardSections.parse(%{sheets: [notes]}, %{gstin: @gstin}, "2026-08")

    assert message =~ "Conflicting type across rows 2, 3"
  end

  test "separates GSTIN-bearing notes in the CDNUR sheet without losing provenance" do
    b2b =
      sheet("B2B", [
        row(1, @headers),
        row(2, %{
          "A" => "33AAACR7926B1ZP",
          "C" => "A1",
          "D" => "01-Aug-2026",
          "E" => "118",
          "F" => "33-Tamil Nadu",
          "K" => "18",
          "L" => "100"
        })
      ])

    cdnur =
      sheet("CDNUR", [
        row(1, %{
          "A" => "UR Type",
          "B" => "Note Number",
          "C" => "Note Date",
          "D" => "Note Type",
          "E" => "Place Of Supply",
          "F" => "Note Value",
          "G" => "Applicable % of Tax Rate",
          "H" => "Rate",
          "I" => "Taxable Value",
          "J" => "Cess Amount"
        }),
        row(2, %{
          "A" => "B2CL",
          "B" => "N1",
          "C" => "04-Aug-2026",
          "D" => "C",
          "E" => "33 - Tamil Nadu",
          "F" => "105",
          "H" => "5",
          "I" => "100"
        }),
        row(3, %{
          "A" => "33AAACR7926B1ZP",
          "B" => "N2",
          "C" => "04-Aug-2026",
          "D" => "C",
          "E" => "33 - Tamil Nadu",
          "F" => "105",
          "G" => "Regular B2B",
          "H" => "5",
          "I" => "100"
        })
      ])

    assert {:ok, %{"rows" => rows}} =
             StandardSections.parse(%{sheets: [b2b, cdnur]}, %{gstin: @gstin}, "2026-08")

    assert Enum.frequencies_by(rows, & &1["section"]) == %{"b2b" => 1, "cdnr" => 1, "cdnur" => 1}
    note = Enum.find(rows, &(&1["row"] == 3 and &1["sheet"] == "CDNUR"))
    assert note["section"] == "cdnr"
    assert note["values"]["buyer_gstin"] == "33AAACR7926B1ZP"
    assert note["cells"]["A"] == "33AAACR7926B1ZP"
  end

  test "does not silently skip a short unsupported B2CL sheet" do
    b2b = sheet("B2B", [row(1, @headers)])

    b2cl =
      sheet("B2CL", [
        row(1, %{"A" => "Invoice Number", "F" => "Rate", "G" => "Taxable Value"}),
        row(2, %{"A" => "A1", "F" => "18", "G" => "100"})
      ])

    assert {:error, message} =
             StandardSections.parse(%{sheets: [b2b, b2cl]}, %{gstin: @gstin}, "2026-08")

    assert message =~ "B2CL, row 2: This section has entries"
  end

  test "reads a companion HSN sheet by its filename and the actual headings" do
    b2b =
      sheet("B2B", [
        row(1, @headers),
        row(2, %{
          "A" => "33AAACR7926B1ZP",
          "C" => "A1",
          "D" => "01-Aug-2026",
          "E" => "118",
          "F" => "33-Tamil Nadu",
          "K" => "18",
          "L" => "100"
        })
      ])

    hsn =
      sheet("HSN", [
        row(1, %{
          "A" => "HSN",
          "B" => "Description",
          "C" => "UQC",
          "D" => "Total Quantity",
          "F" => "Taxable Value",
          "G" => "Rate",
          "H" => "Integrated Tax Amount",
          "I" => "Central Tax Amount",
          "J" => "State/UT Tax Amount",
          "K" => "Cess Amount",
          "M" => "HSN"
        }),
        row(2, %{
          "A" => "9403",
          "C" => "PCS-PIECES",
          "D" => "1",
          "F" => "100",
          "G" => "18",
          "H" => "0",
          "I" => "9",
          "J" => "9",
          "K" => "0",
          "M" => "source side calculation"
        })
      ])
      |> Map.put(:source_filename, "HSN(B2B).xlsx")

    assert {:ok, %{"rows" => rows, "format_version" => 1}} =
             StandardSections.parse(%{sheets: [b2b, hsn]}, %{gstin: @gstin}, "2026-08")

    summary = Enum.find(rows, &(&1["section"] == "hsn_b2b"))
    assert summary["values"]["rate"] == 18.0
    assert summary["values"]["txval"] == 100.0
    assert summary["columns"]["rate"] == "G"
    assert summary["columns"]["txval"] == "F"
    assert summary["source_filename"] == "HSN(B2B).xlsx"
    assert summary["cells"]["M"] == "source side calculation"
  end

  test "B2CS supply type combines a local source total with local notes" do
    b2cs =
      sheet("B2CS", [
        row(1, %{
          "A" => "Type",
          "B" => "Place Of Supply",
          "D" => "Rate",
          "E" => "Taxable Value",
          "F" => "Cess Amount"
        }),
        row(2, %{
          "A" => "OE",
          "B" => "33-Tamil Nadu",
          "D" => "18",
          "E" => "100",
          "F" => "0"
        })
      ])

    client = %{gstin: @gstin}
    assert {:ok, report} = StandardSections.parse(%{sheets: [b2cs]}, client, "2026-08")
    assert [%{"values" => %{"supply" => "INTRA"}}] = report["rows"]

    note =
      Nila.Gst.Extraction.Sales.Normalizer.normalize(%{
        "data" => %{
          "document_type" => "credit_note",
          "document_status" => "active",
          "supply_type" => "taxable",
          "recipient_registration" => "unregistered",
          "original_sale_category" => "b2cs",
          "seller" => %{"gstin" => @gstin},
          "buyer" => %{},
          "invoice_number" => "CN1",
          "invoice_date" => "2026-08-01",
          "place_of_supply" => "33",
          "printed_grand_total" => 11.8,
          "reverse_charge" => false,
          "line_items" => [
            %{
              "printed_taxable_value" => 10,
              "cgst_rate" => 9,
              "sgst_rate" => 9,
              "cgst_amount" => 0.9,
              "sgst_amount" => 0.9,
              "igst_amount" => 0
            }
          ]
        }
      })
      |> Map.merge(%{
        "id" => "note",
        "return_report_dump_id" => 1,
        "return_report_section" => "CDNUR"
      })

    projection = Gstr1.project([note], Gstr1.production_header(@gstin, "2026-08"))

    {projection, _, _} =
      ReturnSources.apply(projection, [note], [
        Map.merge(report, %{
          "dump_id" => 1,
          "filename" => "B2CS.xlsx",
          "b2cs_before_notes" => true
        })
      ])

    assert [%{"sply_ty" => "INTRA", "pos" => "33", "rt" => 18.0, "txval" => 90.0}] =
             projection.derived["b2cs"]
  end

  test "keeps supplied HSN, B2CS, document and nil totals in their return sections" do
    client = %{gstin: @gstin}

    b2b =
      sheet("B2B", [
        row(1, @headers),
        row(2, %{
          "A" => "33AAACR7926B1ZP",
          "C" => "A1",
          "D" => "01-Aug-2026",
          "E" => "118",
          "F" => "33-Tamil Nadu",
          "G" => "N",
          "I" => "Regular B2B",
          "K" => "18",
          "L" => "100",
          "M" => "0"
        })
      ])

    b2cs =
      sheet("b2cs", [
        row(4, %{"A" => "Type", "B" => "Place Of Supply", "D" => "Rate", "E" => "Taxable Value"}),
        row(5, %{"A" => "OE", "B" => "33-Tamil Nadu", "D" => "18", "E" => "200", "F" => "0"})
      ])

    hsn =
      sheet("hsn(b2b)", [
        row(4, %{"A" => "HSN", "C" => "UQC", "F" => "Rate", "G" => "Taxable Value"}),
        row(5, %{
          "A" => "9403",
          "C" => "PCS-PIECES",
          "D" => "1",
          "F" => "18",
          "G" => "100",
          "H" => "0",
          "I" => "9",
          "J" => "9",
          "K" => "0"
        })
      ])

    hsn_b2c =
      sheet("hsn(b2c)", [
        row(4, %{"A" => "HSN", "C" => "UQC", "F" => "Rate", "G" => "Taxable Value"}),
        row(5, %{
          "A" => "9403",
          "C" => "PCS-PIECES",
          "D" => "2",
          "F" => "18",
          "G" => "200",
          "H" => "0",
          "I" => "18",
          "J" => "18",
          "K" => "0"
        })
      ])

    docs =
      sheet("docs", [
        row(4, %{
          "A" => "Nature of Document",
          "B" => "Sr. No. From",
          "C" => "Sr. No. To",
          "D" => "Total Number",
          "E" => "Cancelled"
        }),
        row(5, %{
          "A" => "Invoices for outward supply",
          "B" => "A1",
          "C" => "A1",
          "D" => "1",
          "E" => "0"
        })
      ])

    exempt =
      sheet("exemp", [
        row(4, %{"A" => "Description", "B" => "Nil Rated Supplies", "D" => "Non-GST Supplies"}),
        row(5, %{
          "A" => "Intra-State supplies to unregistered persons",
          "B" => "50",
          "C" => "0",
          "D" => "0"
        })
      ])

    assert {:ok, report} =
             StandardSections.parse(
               %{sheets: [b2b, b2cs, hsn, hsn_b2c, docs, exempt]},
               client,
               "2026-08"
             )

    [invoice] = ReturnReport.invoices(report, client)
    projection = Gstr1.project([invoice], Gstr1.production_header(@gstin, "2026-08"))

    {projection, issues, _} =
      ReturnSources.apply(projection, [invoice], [
        Map.merge(report, %{"dump_id" => 1, "filename" => "sample.xlsx"})
      ])

    assert issues == []
    assert [%{"txval" => 200.0}] = projection.derived["b2cs"]
    assert [%{"hsn_sc" => "9403", "uqc" => "PCS"}] = projection.derived["hsn"]["hsn_b2b"]
    assert [%{"sply_ty" => "INTRAB2C", "nil_amt" => 50.0}] = projection.derived["nil"]["inv"]
    assert [%{"doc_num" => 1}] = projection.derived["doc_issue"]["doc_det"]
  end
end
