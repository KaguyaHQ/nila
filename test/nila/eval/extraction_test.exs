defmodule Nila.Eval.ExtractionTest do
  @moduledoc """
  The cache key and the replay seam.

  What matters here is what the key does *not* cover: everything downstream of
  the HTTP response is recomputed on every score, so no edit to a merge or
  mapping rule can be masked by a cache hit.
  """
  use ExUnit.Case, async: true

  alias Nila.Eval.Extraction
  alias Nila.Gst.Extraction.Providers.Mistral

  defp doc(sha \\ "abc123"), do: %{"sha256" => sha, "name" => "test-doc", "kind" => "sales"}

  describe "extract_id/2" do
    test "is stable for the same document and request shape" do
      assert Extraction.extract_id(doc(), :sales) == Extraction.extract_id(doc(), :sales)
    end

    test "changes with the document" do
      refute Extraction.extract_id(doc("aaa"), :sales) ==
               Extraction.extract_id(doc("bbb"), :sales)
    end

    test "changes with the kind, because the prompt and schema differ" do
      refute Extraction.extract_id(doc(), :sales) == Extraction.extract_id(doc(), :purchase)
    end
  end

  describe "Mistral.fingerprint/1" do
    test "names the model and hashes the literals sent to the API" do
      fingerprint = Mistral.fingerprint(:sales)

      assert fingerprint.model == Mistral.model()
      assert fingerprint.prompt =~ ~r/^[0-9a-f]{64}$/
      assert fingerprint.schema =~ ~r/^[0-9a-f]{64}$/
    end

    test "sales and purchase differ in both prompt and schema" do
      sales = Mistral.fingerprint(:sales)
      purchase = Mistral.fingerprint(:purchase)

      refute sales.prompt == purchase.prompt
      refute sales.schema == purchase.schema
    end
  end

  describe "replay/1" do
    setup do
      dir = Path.join(System.tmp_dir!(), "extract_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "raw"))
      on_exit(fn -> File.rm_rf(dir) end)
      %{dir: dir}
    end

    defp write_window!(dir, name, page_numbers, body) do
      File.write!(Path.join([dir, "raw", "#{name}.json"]), body)

      File.write!(
        Path.join([dir, "raw", "#{name}.meta.json"]),
        Jason.encode!(%{"window" => name, "page_numbers" => page_numbers, "status" => 200})
      )
    end

    defp write_meta!(dir, page_count) do
      File.write!(
        Path.join(dir, "meta.json"),
        Jason.encode!(%{"kind" => "sales", "page_count" => page_count})
      )
    end

    defp response_body(invoices, pages) do
      Jason.encode!(%{
        "document_annotation" => Jason.encode!(%{"invoices" => invoices}),
        "pages" => pages,
        "usage_info" => %{"pages_processed" => length(pages)}
      })
    end

    defp invoice(inum) do
      %{
        "invoice_number" => inum,
        "invoice_date" => "04-05-2026",
        "seller" => %{"gstin" => "33AEWPH4158J1Z3"},
        "buyer" => %{"gstin" => "33AABCP9487A1ZG"},
        "line_items" => [%{"taxable_value" => 1000, "cgst_rate" => 9, "cgst_amount" => 90}]
      }
    end

    defp page(index, text) do
      %{"index" => index, "markdown" => text, "images" => []}
    end

    test "rebuilds invoices from cached response bytes", %{dir: dir} do
      write_meta!(dir, 1)

      write_window!(
        dir,
        "whole_document",
        nil,
        response_body([invoice("INV-1")], [page(0, "Invoice INV-1 total 1180")])
      )

      assert {:ok, %{pages: [artifact]}} = Extraction.replay(dir)
      assert artifact["data"]["invoice_number"] == "INV-1"
    end

    test "merges overlapping windows at replay time, not at fetch time", %{dir: dir} do
      write_meta!(dir, 14)

      body = response_body([invoice("INV-1")], [page(6, "Invoice INV-1")])
      write_window!(dir, "pages_001_008", Enum.to_list(1..8), body)
      write_window!(dir, "pages_007_014", Enum.to_list(7..14), body)

      assert {:ok, %{pages: pages}} = Extraction.replay(dir)

      assert length(pages) == 1,
             "the echo collapses when the cache is replayed, so a merge-rule change is visible without re-fetching"
    end

    test "a window holding no invoice leaves its pages unclaimed rather than failing", %{dir: dir} do
      write_meta!(dir, 14)

      write_window!(
        dir,
        "pages_001_008",
        Enum.to_list(1..8),
        response_body([invoice("INV-1")], [page(0, "Invoice INV-1")])
      )

      write_window!(dir, "pages_007_014", Enum.to_list(7..14), response_body([], []))

      assert {:ok, result} = Extraction.replay(dir)
      assert length(result.pages) == 1
      assert 14 in result.unaccounted_pages
    end

    test "a whole-document read with no invoices is still a failure", %{dir: dir} do
      write_meta!(dir, 1)
      write_window!(dir, "whole_document", nil, response_body([], []))

      assert {:error, {:replay_failed, "whole_document", :no_invoices_extracted}} =
               Extraction.replay(dir)
    end

    test "reports the window when a cached body cannot be interpreted", %{dir: dir} do
      write_meta!(dir, 1)
      write_window!(dir, "whole_document", nil, "not json")

      assert {:error, {:replay_failed, "whole_document", _reason}} = Extraction.replay(dir)
    end
  end

  describe "latest_attempt/1" do
    test "says so when a document has never been extracted" do
      assert {:error, {:no_attempt, _name}} =
               Extraction.latest_attempt("caltech-2025-11-sales")
    end
  end
end
