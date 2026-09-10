defmodule Nila.Gst.Extraction.Discovery.PageLabelsTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Extraction.Discovery.PageLabels

  defp label(page, label, invoice_no \\ nil) do
    %{page: page, label: label, invoice_no: invoice_no, reason: nil}
  end

  describe "stitch/1" do
    test "a continuation chain becomes one segment, link by link" do
      segments =
        PageLabels.stitch([
          label(1, :start, "INV-1"),
          label(2, :continuation),
          label(3, :continuation),
          label(4, :start, "INV-2")
        ])

      assert Enum.map(segments, & &1.pages) == [[1, 2, 3], [4]]
      assert Enum.map(segments, & &1.invoice_no) == ["INV-1", "INV-2"]
    end

    test "a non-invoice closes the run rather than absorbing the next page" do
      segments =
        PageLabels.stitch([
          label(1, :start, "INV-1"),
          label(2, :non_invoice),
          label(3, :continuation)
        ])

      assert Enum.map(segments, &{&1.pages, &1.kind}) ==
               [{[1], :invoice}, {[2], :non_invoice}, {[3], :invoice}]
    end

    test "a continuation with nothing open becomes a start and says so" do
      # The alternative is a page belonging to no segment, which is the silence
      # this pipeline exists to remove.
      [segment] = PageLabels.stitch([label(1, :continuation)])

      assert segment.pages == [1]
      assert segment.kind == :invoice
      assert {:continuation_without_start, 1} in segment.issues
    end

    test "every page lands in exactly one segment, whatever the labels say" do
      labels =
        Enum.map(1..9, fn page ->
          label(page, Enum.at([:start, :continuation, :non_invoice, :unreadable], rem(page, 4)))
        end)

      pages = PageLabels.stitch(labels) |> Enum.flat_map(& &1.pages) |> Enum.sort()

      assert pages == Enum.to_list(1..9)
    end
  end
end
