defmodule Nila.Gst.Extraction.WindowedPageCountTest do
  # Swaps the `pdfinfo` binary application-wide, so it runs alone.
  use ExUnit.Case, async: false

  alias Nila.Gst.Extraction.Windowed
  alias Nila.PdfFixtures

  setup do
    original = Application.get_env(:nila, Windowed, [])
    on_exit(fn -> Application.put_env(:nila, Windowed, original) end)
    :ok
  end

  test "a missing pdfinfo fails loudly rather than silently widening the window" do
    Application.put_env(:nila, Windowed, pdfinfo: "nila-no-such-pdfinfo")

    assert {:error, {:pdf_page_count_failed, _message}} =
             Windowed.extract(:purchase, PdfFixtures.pdf(14), filename: "bills.pdf")
  end

  @tag :capture_log
  test "bytes pdfinfo can't read fall back to one whole-document call" do
    Req.Test.stub(Nila.Gst.Extraction.Providers.Mistral, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      refute Map.has_key?(Jason.decode!(body), "pages")

      Req.Test.json(conn, %{
        "pages" => [%{"index" => 0, "markdown" => "Invoice A-1", "blocks" => []}],
        "document_annotation" => %{
          "invoices" => [
            %{
              "source_pages" => [1],
              "invoice_number" => "A-1",
              "seller" => %{"name" => "Dawn Power", "gstin" => "32AAMFD7558A1ZL"},
              "line_items" => []
            }
          ]
        },
        "usage_info" => %{"pages_processed" => 1}
      })
    end)

    assert {:ok, result} =
             Windowed.extract(:purchase, "%PDF-1.7 not really a pdf", filename: "bills.pdf")

    assert [artifact] = result.pages
    assert artifact["source_pages"] == [1]
    assert result.unaccounted_pages == []
  end
end
