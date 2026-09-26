defmodule Nila.Gst.Sales.Excel.ReturnReportDedupTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Sales.Excel.ReturnReport

  defp values(overrides) do
    Map.merge(
      %{
        "seller_gstin" => "09AAJFR9181R1ZJ",
        "buyer_gstin" => "33CMJPT7908P1Z5",
        "number" => "SR/26-27/000981",
        "date" => "2026-08-25",
        "note_type" => "C",
        "value" => 1217.45,
        "pos" => "33",
        "invoice_type" => "R",
        "rate" => 5.0,
        "txval" => 1159.47,
        "iamt" => 57.97,
        "camt" => 0.0,
        "samt" => 0.0,
        "csamt" => 0.0,
        "period" => "082026"
      },
      overrides
    )
  end

  defp source(filename, sheet, row, values) do
    %{
      "source_filename" => filename,
      "sheet" => sheet,
      "section" => "cdnr",
      "row" => row,
      "values" => values
    }
  end

  test "identical registered notes from CDNR and CDNUR count once with both source rows" do
    registered =
      source(
        "CDNR.xlsx",
        "CDNR",
        15,
        values(%{"buyer_name" => "Anil Store", "reverse_charge" => "N"})
      )

    repeated =
      source("CDNUR.xlsx", "CDNUR", 323, values(%{"source_ur_type" => "33CMJPT7908P1Z5"}))

    assert [invoice] = ReturnReport.invoices(%{"rows" => [registered, repeated]}, %{})
    assert invoice["source_filename"] == "CDNR.xlsx"
    assert invoice["buyer_name"] == "Anil Store"
    assert invoice["reverse_charge"] == false
    assert length(invoice["line_items"]) == 1
    assert length(invoice["return_report_values"]) == 2

    assert invoice["source_refs"] == [
             %{"source_filename" => "CDNR.xlsx", "sheet" => "CDNR", "row" => 15},
             %{"source_filename" => "CDNUR.xlsx", "sheet" => "CDNUR", "row" => 323}
           ]
  end

  test "a changed tax amount or nonblank buyer name remains a separate note" do
    registered = source("CDNR.xlsx", "CDNR", 15, values(%{"buyer_name" => "Anil Store"}))
    changed_tax = source("CDNUR.xlsx", "CDNUR", 323, values(%{"iamt" => 58.0}))
    changed_name = source("CDNUR.xlsx", "CDNUR", 323, values(%{"buyer_name" => "Other Store"}))

    assert length(ReturnReport.invoices(%{"rows" => [registered, changed_tax]}, %{})) == 2
    assert length(ReturnReport.invoices(%{"rows" => [registered, changed_name]}, %{})) == 2
  end
end
