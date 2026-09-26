defmodule Nila.Gst.Sales.CsvWorkbookTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Sales.Excel.{CsvWorkbook, StandardSections}

  test "reads GST section CSV with BOM and quoted cells" do
    csv =
      <<0xEF, 0xBB, 0xBF>> <>
        "GSTIN/UIN of Recipient,Receiver Name,Invoice Number,Invoice date,Invoice Value,Place Of Supply,Reverse Charge,Applicable % of Tax Rate,Invoice Type,E-Commerce GSTIN,Rate,Taxable Value,Cess Amount\r\n" <>
        ~s(33AAACI5950L1ZH,"ITC, Limited",A1,15-Jul-26,118,33-Tamil Nadu,N,,Regular B2B,,18,100,0\r\n)

    assert {:ok, %{sheets: [sheet], date1904?: false} = workbook} = CsvWorkbook.read(csv)
    assert StandardSections.matches?(workbook)
    assert sheet.name == "B2B"
    assert Enum.map(sheet.rows, & &1.row) == [1, 2]
    assert Enum.at(sheet.rows, 1).cells["B"] == "ITC, Limited"
    assert Enum.at(sheet.rows, 1).cells["M"] == "0"
  end

  test "rejects malformed and oversized CSV" do
    assert {:error, :invalid_file} = CsvWorkbook.read(<<0xFF>>)
    assert {:error, :invalid_file} = CsvWorkbook.read("\"unterminated")
    assert {:error, :invalid_file} = CsvWorkbook.read("")
    assert {:error, :too_large} = CsvWorkbook.read(String.duplicate("a", 5_000_001))
    assert {:error, :too_large} = CsvWorkbook.read(Enum.join(List.duplicate("x", 101), ","))
    assert {:error, :too_large} = CsvWorkbook.read(String.duplicate("x\n", 5_002))
  end
end
