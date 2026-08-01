defmodule Nila.Gst.Extraction.EvidenceTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Extraction.Evidence
  alias Nila.PdfFixtures

  test "renders every PDF page and binds an artifact to its attributed page" do
    result = result([artifact([3])])

    attached = Evidence.attach(result, PdfFixtures.pdf(5), filename: "bills.pdf")

    assert attached.images |> Map.keys() |> Enum.sort() ==
             ~w(page_01.png page_02.png page_03.png page_04.png page_05.png)

    assert Enum.all?(Map.values(attached.images), &(byte_size(&1) > 0))
    assert [%{"image" => "page_03.png"}] = attached.pages
    refute Map.has_key?(attached, :evidence_error)
  end

  test "an artifact without page attribution points at no image" do
    attached = Evidence.attach(result([artifact([])]), PdfFixtures.pdf(1), filename: "bill.pdf")

    assert [%{"image" => nil}] = attached.pages
  end

  @tag :capture_log
  test "an unrenderable PDF preserves artifacts and reports the evidence gap" do
    attached =
      Evidence.attach(result([artifact([1])]), "%PDF-1.4 truncated", filename: "bill.pdf")

    assert [%{"image" => nil}] = attached.pages
    assert attached.images == %{}
    assert {:page_render_failed, 1, _output} = attached.evidence_error
  end

  test "an image needs no PDF rasterization" do
    attached =
      Evidence.attach(result([artifact([1])]), <<0xFF, 0xD8, 0xFF, 0x00>>, filename: "bill.jpg")

    assert attached.images == %{}
    assert [%{"image" => nil}] = attached.pages
    refute Map.has_key?(attached, :evidence_error)
  end

  test "uses stable page basenames" do
    assert Evidence.page_basename(1) == "page_01.png"
    assert Evidence.page_basename(120) == "page_120.png"
  end

  defp result(pages), do: %{pages: pages, images: %{}, audit: %{}, unaccounted_pages: []}

  defp artifact(source_pages), do: %{"source_pages" => source_pages, "image" => nil}
end
