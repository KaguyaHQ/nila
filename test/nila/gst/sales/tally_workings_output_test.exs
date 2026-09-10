defmodule Nila.Gst.Sales.TallyWorkingsOutputTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias Nila.Gst.Extraction.Sales.Normalizer
  alias Nila.Gst.Sales.Workings
  alias Nila.Gst.Sales.Workings.Xlsx, as: WorkingsXlsx
  alias NilaWeb.Components.Gst.Month.Workings, as: Component
  @endpoint NilaWeb.Endpoint
  @root Path.expand("../../../fixtures/gstr1/tally", __DIR__)

  test "native note and Table 8 schedules survive screen and spreadsheet projection" do
    for {month, selector, label} <- [
          {"02", "#gstr1-workings-cdnr-rows", "NU-CN-B"},
          {"03", "#gstr1-workings-nil-rows", "Within state"}
        ] do
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

      html =
        render_component(&Component.workings_body/1,
          derived: result.derived,
          invoices: result.invoices,
          open_folds: MapSet.new(~w(gstr1-workings-cdnr gstr1-workings-nil))
        )

      assert html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> LazyHTML.text() =~
               label

      {:ok, binary} =
        WorkingsXlsx.build(result, %{name: "CALTECH", gstin: "33BPBPK1081A1ZO"}, "2026-#{month}")

      {:ok, files} = :zip.extract(binary, [:memory])
      strings = files |> Map.new() |> Map.fetch!(~c"xl/sharedStrings.xml")
      assert strings =~ if(month == "02", do: "CDNUR", else: "Table 8 - Non-GST")
    end
  end
end
