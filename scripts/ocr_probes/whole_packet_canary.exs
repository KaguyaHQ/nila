defmodule OcrProbe.WholePacketCanary do
  @moduledoc false

  # The 57-page Breezetech October packet is the canary: whole-document
  # annotation drops invoice RAC2451 (page 51) and emits 39 duplicate entries,
  # with HTTP 200. Run it two ways:
  #
  #   mix run scripts/ocr_probes/whole_packet_canary.exs           # windowed (acceptance)
  #   mix run scripts/ocr_probes/whole_packet_canary.exs whole     # one call (the failure)
  #
  # Acceptance for `Nila.Gst.Extraction.Windowed`: RAC2451 present, ~42 unique
  # invoices, and every unaccounted page humanly explicable.

  alias Nila.Gst.Extraction.Providers.Mistral
  alias Nila.Gst.Extraction.Windowed

  @path "/Users/vasanthk/Documents/data/demo/purchase/Breezetech October month purchase bills-2025-26.pdf"
  @canary "RAC2451"

  def run(["whole" | _rest]), do: whole()
  def run(_argv), do: windowed()

  defp windowed do
    bytes = File.read!(@path)
    IO.puts("windowed run: 57p breezetech-oct bytes=#{byte_size(bytes)}")
    started = System.monotonic_time(:millisecond)

    result = Windowed.extract(:purchase, bytes, filename: Path.basename(@path))

    ms = System.monotonic_time(:millisecond) - started

    case result do
      {:ok, %{pages: artifacts, unaccounted_pages: unaccounted, audit: audit}} ->
        numbers = Enum.map(artifacts, &get_in(&1, ["data", "invoice_number"]))

        IO.puts("#{ms}ms windows=#{audit.windows} pages=#{audit.source_page_count}")
        IO.puts("artifacts=#{length(artifacts)} unique=#{numbers |> Enum.uniq() |> length()}")
        IO.puts("#{@canary} present: #{canary?(numbers)}")
        IO.puts("unaccounted pages (#{length(unaccounted)}): #{inspect(unaccounted)}")
        IO.puts("\nall invoice numbers:")
        numbers |> Enum.with_index(1) |> Enum.each(fn {n, i} -> IO.puts("  #{i}. #{n}") end)

      {:error, reason} ->
        IO.puts("#{ms}ms ERROR #{inspect(reason)}")
    end
  end

  defp whole do
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
          |> Enum.filter(fn {p, _i} ->
            String.contains?(String.upcase(p["markdown"] || ""), @canary)
          end)
          |> Enum.map(fn {p, i} -> if is_integer(p["index"]), do: p["index"] + 1, else: i end)

        IO.puts("#{ms}ms status=#{status}")
        IO.puts("pages_processed=#{pages_processed}  pages_returned=#{length(pages)}")
        IO.puts("annotation invoices=#{length(invoices)}")
        IO.puts("#{@canary} in OCR page markdown: #{inspect(rac_ocr_pages)}")
        IO.puts("#{@canary} in annotation invoices: #{canary?(inums)}")
        IO.puts("\nall invoice numbers (#{length(inums)}):")
        inums |> Enum.with_index(1) |> Enum.each(fn {n, i} -> IO.puts("  #{i}. #{n}") end)

        File.mkdir_p!("tmp/mistral_timing_probe")
        File.write!("tmp/mistral_timing_probe/57page_raw.json", raw)
        IO.puts("\nwrote tmp/mistral_timing_probe/57page_raw.json (#{byte_size(raw)} bytes)")

      {:error, reason} ->
        IO.puts("#{ms}ms ERROR #{inspect(reason)}")
    end
  end

  defp canary?(numbers) do
    Enum.any?(numbers, &(&1 && String.contains?(String.upcase(&1), @canary)))
  end

  defp decode_ann(a) when is_map(a), do: a

  defp decode_ann(a) when is_binary(a),
    do: with({:ok, m} <- Jason.decode(a), do: m, else: (_ -> nil))

  defp decode_ann(_), do: nil
end

OcrProbe.WholePacketCanary.run(System.argv())
