defmodule Nila.PdfFixtures do
  @moduledoc """
  Minimal, structurally valid PDFs for tests that only care about page count —
  `Nila.Gst.Extraction.Windowed` reads it with `pdfinfo` before planning
  windows, so the bytes must be a PDF poppler will actually open.
  """

  @doc "A valid PDF of `page_count` blank pages."
  def pdf(page_count) when page_count >= 1 do
    kids = Enum.map_join(3..(page_count + 2), " ", &"#{&1} 0 R")

    objects =
      [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [#{kids}] /Count #{page_count} >>"
      ] ++
        for(_page <- 1..page_count, do: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>")

    {body, offsets} =
      objects
      |> Enum.with_index(1)
      |> Enum.reduce({"%PDF-1.4\n", []}, fn {object, number}, {acc, offsets} ->
        {acc <> "#{number} 0 obj\n#{object}\nendobj\n", [byte_size(acc) | offsets]}
      end)

    size = length(objects) + 1

    xref =
      offsets
      |> Enum.reverse()
      |> Enum.map_join(&(String.pad_leading(to_string(&1), 10, "0") <> " 00000 n \n"))

    body <>
      "xref\n0 #{size}\n0000000000 65535 f \n" <>
      xref <>
      "trailer\n<< /Size #{size} /Root 1 0 R >>\nstartxref\n#{byte_size(body)}\n%%EOF\n"
  end
end
