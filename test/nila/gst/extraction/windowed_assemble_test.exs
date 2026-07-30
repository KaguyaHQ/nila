defmodule Nila.Gst.Extraction.WindowedAssembleTest do
  @moduledoc """
  The overlap merge, on synthetic window results.

  These rules decide which of two reads of the same invoice reaches the register,
  and until `assemble/2` was public the only way to reach them was a live
  provider call. Nothing here touches the network.
  """
  use ExUnit.Case, async: true

  alias Nila.Gst.Extraction.Windowed

  defp artifact(inum, source_pages, overrides \\ %{}) do
    data =
      Map.merge(
        %{
          "invoice_number" => inum,
          "seller" => %{"gstin" => "33AEWPH4158J1Z3"},
          "line_items" => [%{"taxable_value" => 100}]
        },
        Map.get(overrides, "data", %{})
      )

    %{
      "page" => List.first(source_pages),
      "source_pages" => source_pages,
      "data" => data
    }
  end

  defp window(range, artifacts) do
    %{window: range, result: %{pages: artifacts, images: %{}, audit: %{}}}
  end

  describe "page ledger" do
    test "reports every page no artifact claimed" do
      result = Windowed.assemble([window(1..8, [artifact("A", [1])])], 8)

      assert result.unaccounted_pages == [2, 3, 4, 5, 6, 7, 8]
    end

    test "a fully claimed document leaves nothing unaccounted" do
      windows = [window(1..2, [artifact("A", [1]), artifact("B", [2])])]

      assert Windowed.assemble(windows, 2).unaccounted_pages == []
    end

    test "a multi-page invoice claims all of its pages" do
      windows = [window(1..3, [artifact("A", [1, 2, 3])])]

      assert Windowed.assemble(windows, 3).unaccounted_pages == []
    end
  end

  describe "overlap echoes" do
    test "the same invoice read by two overlapping windows collapses to one" do
      windows = [
        window(1..8, [artifact("INV-1", [7])]),
        window(7..14, [artifact("INV-1", [7])])
      ]

      assert %{pages: [invoice]} = Windowed.assemble(windows, 14)
      assert invoice["source_pages"] == [7]
    end

    test "the richer read of an echoed invoice survives" do
      thin = artifact("INV-1", [7])

      rich =
        artifact("INV-1", [7], %{
          "data" => %{
            "invoice_number" => "INV-1",
            "buyer" => %{"gstin" => "33AABCP9487A1ZG"},
            "line_items" => [%{"taxable_value" => 100}, %{"taxable_value" => 200}]
          }
        })

      windows = [window(1..8, [thin]), window(7..14, [rich])]

      assert %{pages: [invoice]} = Windowed.assemble(windows, 14)
      assert length(invoice["data"]["line_items"]) == 2
    end

    test "the same invoice number on pages that do not touch is left alone" do
      windows = [
        window(1..8, [artifact("INV-1", [2])]),
        window(7..14, [artifact("INV-1", [12])])
      ]

      assert %{pages: pages} = Windowed.assemble(windows, 14)

      assert length(pages) == 2,
             "a genuine duplicate is a business question for review, not a merge"
    end

    test "different invoices in the overlap both survive" do
      windows = [
        window(1..8, [artifact("INV-1", [7])]),
        window(7..14, [artifact("INV-2", [7])])
      ]

      assert %{pages: pages} = Windowed.assemble(windows, 14)
      assert length(pages) == 2
    end
  end

  describe "artifacts without an invoice number" do
    test "are never merged into each other" do
      windows = [
        window(1..8, [artifact("", [7])]),
        window(7..14, [artifact("", [7])])
      ]

      assert %{pages: pages} = Windowed.assemble(windows, 14)

      assert length(pages) == 2,
             "no key means no identity; collapsing them would invent one"
    end
  end

  describe "audit" do
    test "sums usage across windows and records how many there were" do
      windows = [
        %{
          window: 1..8,
          result: %{pages: [], images: %{}, audit: %{usage: %{pages_processed: 8}}}
        },
        %{
          window: 7..14,
          result: %{pages: [], images: %{}, audit: %{usage: %{pages_processed: 8}}}
        }
      ]

      assert %{audit: audit} = Windowed.assemble(windows, 14)
      assert audit.usage.pages_processed == 16
      assert audit.windows == 2
      assert audit.source_page_count == 14
    end

    test "falls back to the provider's page count when pdfinfo could not read the document" do
      windows = [
        %{
          window: :whole_document,
          result: %{pages: [], images: %{}, audit: %{source_page_count: 3}}
        }
      ]

      assert %{audit: %{source_page_count: 3}} = Windowed.assemble(windows, :unknown)
    end
  end

  describe "ordering" do
    test "artifacts come back in page order" do
      windows = [window(1..8, [artifact("C", [5]), artifact("A", [1]), artifact("B", [3])])]

      assert %{pages: pages} = Windowed.assemble(windows, 8)
      assert Enum.map(pages, & &1["data"]["invoice_number"]) == ["A", "B", "C"]
    end
  end
end
