defmodule Nila.Gst.Extraction.NativeTextTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Extraction.NativeText
  alias Nila.PdfFixtures

  test "keeps exact identifiers and physical positions of blank pages" do
    pdf = PdfFixtures.text_pdf(["GSTIN 33AAICE0305R1ZM", "", "Invoice ETS-26-27-0022", "", ""])
    assert {:ok, pages} = NativeText.extract(pdf, 5)
    assert map_size(pages) == 5
    assert pages[1] =~ "33AAICE0305R1ZM"
    assert pages[3] =~ "ETS-26-27-0022"
    assert Enum.all?([2, 4, 5], &(String.trim(pages[&1]) == ""))
  end

  test "preserves a wholly blank packet for vision and rejects page count mismatches" do
    assert {:ok, %{1 => "", 2 => ""}} = NativeText.extract(PdfFixtures.pdf(2), 2)
    assert {:error, {:native_text_page_count, 1, 2}} = NativeText.extract(PdfFixtures.pdf(2), 1)
  end

  test "invalid PDFs return a failure rather than treating diagnostics as source text" do
    assert {:error, {:native_text_failed, _, _}} = NativeText.extract("not a PDF", 1)
  end
end
