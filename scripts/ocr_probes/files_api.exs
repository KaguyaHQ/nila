# Live check of the Mistral Files API contract that `Nila.Gst.Extraction.Windowed`
# now depends on: upload -> signed URL -> delete.
#
# Everything else about the shared-document path is covered by stubs in
# test/nila/gst/extraction/windowed_shared_document_test.exs. What stubs cannot
# tell us is whether the real endpoints agree with the docs: the multipart field
# names, the `id` in the upload response, the `url` in the signed-URL response,
# and whether DELETE actually removes the file.
#
# No OCR call either way, so no inference is billed.
#
#     # contract only: a few hundred bytes of generated PDF, no client data
#     mix run scripts/ocr_probes/files_api.exs
#
#     # the same round trip with a real packet, to see what a big upload costs
#     mix run scripts/ocr_probes/files_api.exs breeze-2025-10-purchase

alias Nila.Gst.Extraction.Providers.Mistral

defmodule Probe do
  # `Nila.PdfFixtures` lives in test/support, which dev does not compile, and a
  # probe should not be a reason to move test scaffolding into lib.
  def pdf(page_count) do
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

  def check(label, fun) do
    case fun.() do
      {:ok, value} ->
        IO.puts("  ok    #{label}")
        value

      other ->
        IO.puts("  FAIL  #{label}\n        #{inspect(other, pretty: true, limit: 10)}")
        System.halt(1)
    end
  end

  # Decimal MB, because the only number these are compared against is Mistral's
  # documented 50 MB limit. Mixing MiB display with an MB ceiling is how you talk
  # yourself into believing a packet fits when it doesn't.
  def mb(bytes), do: "#{Float.round(bytes / 1_000_000, 1)} MB"

  # Same pdfinfo the extractor uses, so the window count here is the real one.
  def page_count(bytes) do
    path =
      Path.join(System.tmp_dir!(), "nila_files_probe_#{System.unique_integer([:positive])}.pdf")

    File.write!(path, bytes)

    try do
      case System.cmd("pdfinfo", [path], stderr_to_stdout: true) do
        {output, 0} ->
          case Regex.run(~r/^Pages:\s+(\d+)/m, output) do
            [_match, count] -> String.to_integer(count)
            nil -> 1
          end

        _ ->
          1
      end
    after
      File.rm(path)
    end
  end
end

if is_nil(Application.get_env(:nila, Mistral, [])[:api_key]) do
  IO.puts("MISTRAL_API_KEY is not set for this environment. Nothing to probe.")
  System.halt(1)
end

{pdf, label} =
  case System.argv() do
    [] ->
      {Probe.pdf(3), "generated 3-page fixture"}

    [arg] ->
      # A corpus name, or any path on disk — a packet worth probing is often one
      # that just landed in Downloads and is not in the corpus yet.
      path = if File.regular?(arg), do: arg, else: Nila.EvalCorpus.fetch!(arg)
      {File.read!(path), Path.basename(path)}
  end

windows = pdf |> Probe.page_count() |> Nila.Gst.Extraction.Windowed.plan() |> length()
inline = trunc(Float.ceil(byte_size(pdf) / 3) * 4)

# Mistral's documented document limit. Inlining spends the 4/3 base64 expansion
# against it, so the effective ceiling for an inlined packet is ~37.5 MB.
ocr_limit = 50 * 1_000_000

IO.puts("""

Mistral Files API probe — #{label}
  size            #{Probe.mb(byte_size(pdf))}
  windows         #{windows}
  inlined         #{Probe.mb(inline)} per body, #{Probe.mb(inline * windows)} across #{windows} bodies
  uploaded once   #{Probe.mb(byte_size(pdf))}
  vs 50 MB limit  inlined #{Probe.mb(inline)} #{if inline > ocr_limit, do: "OVER — inlining would be rejected", else: "under, with #{Probe.mb(ocr_limit - inline)} to spare"}
""")

{upload_us, %{file_id: file_id, document: document}} =
  :timer.tc(fn ->
    Probe.check("POST /v1/files + GET /v1/files/:id/url", fn ->
      Mistral.upload(pdf, "nila-files-api-probe.pdf")
    end)
  end)

IO.puts("        took:         #{Float.round(upload_us / 1_000_000, 1)}s")
IO.puts("        file_id:      #{file_id}")
IO.puts("        document_url: #{String.slice(document.document_url, 0, 72)}...")

unless document.type == "document_url" and is_binary(document.document_url) do
  IO.puts("  FAIL  document payload is not the shape /v1/ocr expects")
  System.halt(1)
end

Probe.check("DELETE /v1/files/:id", fn ->
  case Mistral.delete(file_id) do
    :ok -> {:ok, :deleted}
    other -> other
  end
end)

IO.puts("""

All three endpoints match what lib/nila/gst/extraction/providers/mistral.ex assumes.
The shared-document path is safe to leave on.
""")
