defmodule Nila.Gst.Sales.TableReaderTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Sales.Excel.{TablePlan, TableReader}

  @plan %TablePlan{
    kind: :invoice,
    fields: %{"number" => ["Invoice Number"], "taxable" => ["Taxable Value"]},
    required: ~w(number taxable)
  }

  test "a duplicate required heading is ambiguous" do
    sheet = %{
      name: "Sales",
      rows: [%{row: 1, cells: %{"A" => "Invoice Number", "B" => "Invoice Number", "C" => "Taxable Value"}}]
    }

    assert catch_throw(TableReader.read!(sheet, @plan)) ==
             {:report_error, "Sales, row 1: Ambiguous invoice headings."}
  end

  test "a nonempty row with no bound fields cannot disappear" do
    sheet = %{
      name: "Sales",
      rows: [
        %{row: 1, cells: %{"A" => "Invoice Number", "B" => "Taxable Value"}},
        %{row: 2, cells: %{"C" => "another sale"}}
      ]
    }

    assert catch_throw(TableReader.read!(sheet, @plan)) ==
             {:report_error, "Sales, row 2: Unrecognized data below the table headings."}
  end
end
