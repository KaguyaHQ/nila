defmodule Nila.PdfFixtures do
  @moduledoc """
  Minimal, structurally valid PDFs for tests that need Poppler to count or
  render pages without carrying real invoice fixtures.
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

    encode(objects)
  end

  @doc "A PDF with one plain-text line per physical page; empty strings make blank pages."
  def text_pdf(pages) when is_list(pages) and pages != [] do
    font = 3 + length(pages) * 2
    kids = pages |> Enum.with_index() |> Enum.map_join(" ", fn {_, i} -> "#{3 + i * 2} 0 R" end)

    objects =
      [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [#{kids}] /Count #{length(pages)} >>"
      ] ++
        Enum.flat_map(Enum.with_index(pages), fn {text, i} ->
          text =
            text
            |> String.replace("\\", "\\\\")
            |> String.replace("(", "\\(")
            |> String.replace(")", "\\)")

          stream = "BT /F1 10 Tf 10 100 Td (#{text}) Tj ET"

          [
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 200] /Resources << /Font << /F1 #{font} 0 R >> >> /Contents #{4 + i * 2} 0 R >>",
            "<< /Length #{byte_size(stream)} >>\nstream\n#{stream}\nendstream"
          ]
        end) ++ ["<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]

    encode(objects)
  end

  defp encode(objects) do
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
