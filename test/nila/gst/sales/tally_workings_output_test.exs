defmodule Nila.Gst.Sales.TallyWorkingsOutputTest do
  use ExUnit.Case, async: true
  alias Nila.Gst.Extraction.Sales.Normalizer
  alias Nila.Gst.Sales.Workings
  alias Nila.Gst.Sales.Workings.Xlsx, as: WorkingsXlsx
  @root Path.expand("../../../fixtures/gstr1/tally", __DIR__)

  test "native note and Table 8 schedules survive spreadsheet projection" do
    for month <- ["02", "03"] do
      read = fn name ->
        @root |> Path.join("2026-#{month}/#{name}") |> File.read!() |> Jason.decode!()
      end

      invoices = Enum.map(read.("extraction.json")["pages"], &Normalizer.normalize/1)

      result =
        Workings.materialize(
          invoices,
          read.("review.json"),
          Map.take(read.("native-gstr1.json"), ~w(gstin fp))
        )

      {:ok, binary} =
        WorkingsXlsx.build(result, %{name: "CALTECH", gstin: "33BPBPK1081A1ZO"}, "2026-#{month}")

      {:ok, files} = :zip.extract(binary, [:memory])
      strings = files |> Map.new() |> Map.fetch!(~c"xl/sharedStrings.xml")
      assert strings =~ if(month == "02", do: "CDNUR", else: "Table 8 - Non-GST")
    end
  end
end
