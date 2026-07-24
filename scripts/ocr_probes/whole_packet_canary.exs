defmodule OcrProbe.WholePacketCanary do
  @moduledoc false

  alias Nila.Gst.Extraction.Providers.Mistral

  @path "/Users/vasanthk/Documents/data/demo/purchase/Breezetech October month purchase bills-2025-26.pdf"

  def run do
    bytes = File.read!(@path)
    payload = Mistral.request_payload(:purchase, bytes, "application/pdf")
    config = Application.get_env(:nila, Mistral, [])
    base_url = config[:base_url] || "https://api.mistral.ai"

    IO.puts("sending 57p breezetech-oct bytes=#{byte_size(bytes)} with 600s timeout...")
    started = System.monotonic_time(:millisecond)

    result =
      Req.post(
        url: base_url <> "/v1/ocr",
        auth: {:bearer, config[:api_key]},
        json: payload,
        decode_body: false,
        retry: false,
        receive_timeout: 600_000
      )

    ms = System.monotonic_time(:millisecond) - started

    case result do
      {:ok, %Req.Response{status: status, body: body}} ->
        raw = IO.iodata_to_binary(body)
        map = Jason.decode!(raw)
        usage = map["usage_info"] || %{}
        pages = map["pages"] || []
        ann = decode_ann(map["document_annotation"])
        invoices = if is_map(ann), do: ann["invoices"] || [], else: []
        inums = Enum.map(invoices, & &1["invoice_number"])

        pages_processed = usage["pages_processed"] || length(pages)

        # Which physical pages does the OCR text mention RAC2451 on?
        rac_ocr_pages =
          pages
          |> Enum.with_index(1)
          |> Enum.filter(fn {p, _i} -> String.contains?(String.upcase(p["markdown"] || ""), "RAC2451") end)
          |> Enum.map(fn {p, i} -> if is_integer(p["index"]), do: p["index"] + 1, else: i end)

        rac_in_annotation = Enum.any?(inums, &(&1 && String.contains?(String.upcase(&1), "RAC2451")))

        IO.puts("#{ms}ms status=#{status}")
        IO.puts("pages_processed=#{pages_processed}  pages_returned=#{length(pages)}")
        IO.puts("annotation invoices=#{length(invoices)}")
        IO.puts("RAC2451 in OCR page markdown: #{inspect(rac_ocr_pages)}")
        IO.puts("RAC2451 in annotation invoices: #{rac_in_annotation}")
        IO.puts("\nall invoice numbers (#{length(inums)}):")
        inums |> Enum.with_index(1) |> Enum.each(fn {n, i} -> IO.puts("  #{i}. #{n}") end)

        File.mkdir_p!("tmp/mistral_timing_probe")
        File.write!("tmp/mistral_timing_probe/57page_raw.json", raw)
        IO.puts("\nwrote tmp/mistral_timing_probe/57page_raw.json (#{byte_size(raw)} bytes)")

      {:error, reason} ->
        IO.puts("#{ms}ms ERROR #{inspect(reason)}")
    end
  end

  defp decode_ann(a) when is_map(a), do: a
  defp decode_ann(a) when is_binary(a), do: with({:ok, m} <- Jason.decode(a), do: m, else: (_ -> nil))
  defp decode_ann(_), do: nil
end

OcrProbe.WholePacketCanary.run()
