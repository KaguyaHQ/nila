defmodule Nila.Gst.Sales.Excel.ReportPacketTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Sales.Excel.ReportPacket

  @b2b "GSTIN/UIN of Recipient,,Invoice Number,Invoice date,Invoice Value,Place Of Supply,,,,,Rate,Taxable Value\n"
  @b2cs "Type,Place Of Supply,,Rate,Taxable Value\n"

  test "keeps source filenames when it combines different section files" do
    files = [
      %{filename: "B2B.csv", bytes: @b2b},
      %{filename: "B2CS.csv", bytes: @b2cs}
    ]

    assert {:ok, {^files, workbook}} = ReportPacket.prepare(files)

    assert Enum.map(workbook.sheets, &{&1.name, &1.source_filename}) ==
             [{"B2B", "B2B.csv"}, {"B2CS", "B2CS.csv"}]
  end

  test "deduplicates identical files before composing the workbook" do
    b2b = %{filename: "B2B.csv", bytes: @b2b}
    assert {:ok, {[^b2b], workbook}} = ReportPacket.prepare([b2b, b2b])
    assert length(workbook.sheets) == 1
  end

  test "rejects two populated exports of the same section" do
    row = "33AABCP9487A1ZG,,A1,01/08/2026,,,,,,,18,100\n"
    b2b = @b2b <> String.duplicate(row, 4)

    assert {:error, message} =
             ReportPacket.prepare([
               %{filename: "first.csv", bytes: b2b},
               %{filename: "second.csv", bytes: b2b <> "\n"}
             ])

    assert message =~ "B2B section has entries in more than one file"
  end

  test "rejects repeated short sections even when their only data is on row two" do
    assert {:error, message} =
             ReportPacket.prepare([
               %{filename: "B2B.csv", bytes: @b2b},
               %{filename: "B2CS.csv", bytes: @b2cs <> "OE,33-Tamil Nadu,,18,50\n"},
               %{filename: "B2CS.csv", bytes: @b2cs <> "OE,33-Tamil Nadu,,18,60\n"}
             ])

    assert message =~ "B2CS section has entries in more than one file"
  end

  test "rejects ProductWise files with an actionable message" do
    assert {:error, message} =
             ReportPacket.prepare([
               %{filename: "B2B.csv", bytes: @b2b},
               %{filename: "ProductWise.csv", bytes: @b2cs}
             ])

    assert message =~ "ProductWise reports cannot be combined"
  end
end
