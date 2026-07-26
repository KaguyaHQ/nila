defmodule OcrProbe.ColdLatencyCurve do
  @moduledoc false

  alias Nila.Gst.Extraction.Providers.Mistral

  # Cold latency curve across sizes. NOTE: these corpus docs have been sent to
  # Mistral before — server-side caching means a rerun may not be truly cold.
  # For a genuine cold point, add a never-sent packet to the corpus first.
  @docs [
    {"3p  may-1", "caltech-2025-05-purchase-part1"},
    {"8p  newdoc", "misc-newdoc-8p"},
    {"9p  maypurahse", "misc-may-pur-ahse-9p"},
    {"13p june-full", "caltech-2025-06-purchase"},
    {"28p june-26", "breeze-2026-06-purchase"}
  ]

  def run do
    rows = Enum.map(@docs, fn {label, name} -> measure({label, Nila.EvalCorpus.fetch!(name)}) end)

    IO.puts("\n================ COLD CURVE (one shot each, never-sent docs) ================")
    IO.puts("doc            bytes       ms      status  pages_processed  invoices")

    Enum.each(rows, fn r ->
      IO.puts(
        String.pad_trailing(r.label, 14) <>
          " " <>
          String.pad_leading(to_string(r.bytes), 9) <>
          "  " <>
          String.pad_leading(to_string(r.ms), 7) <>
          "  " <>
          String.pad_trailing(to_string(r.status), 6) <>
          "  " <>
          String.pad_leading(to_string(r.pages), 15) <>
          "  " <>
          to_string(r.invoices)
      )
    end)

    File.mkdir_p!("tmp/mistral_timing_probe")
    File.write!("tmp/mistral_timing_probe/cold_curve.json", Jason.encode!(rows, pretty: true))
    IO.puts("\nwrote tmp/mistral_timing_probe/cold_curve.json")
  end

  defp measure({label, path}) do
    bytes = File.read!(path)
    payload = Mistral.request_payload(:purchase, bytes, "application/pdf")

    config = Application.get_env(:nila, Mistral, [])
    base_url = config[:base_url] || "https://api.mistral.ai"

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

    {status, pages, invoices} =
      case result do
        {:ok, %Req.Response{status: status, body: body}} ->
          case Jason.decode(IO.iodata_to_binary(body)) do
            {:ok, map} ->
              usage = map["usage_info"] || %{}
              ann = decode_ann(map["document_annotation"])
              inv = if is_map(ann), do: length(ann["invoices"] || []), else: nil
              {status, usage["pages_processed"] || length(map["pages"] || []), inv}

            _ ->
              {status, nil, nil}
          end

        {:error, reason} ->
          {inspect(reason), nil, nil}
      end

    IO.puts("  #{label}: #{ms}ms status=#{status} pages=#{pages} invoices=#{invoices}")
    %{label: label, bytes: byte_size(bytes), ms: ms, status: status, pages: pages, invoices: invoices}
  end

  defp decode_ann(a) when is_map(a), do: a
  defp decode_ann(a) when is_binary(a), do: with({:ok, m} <- Jason.decode(a), do: m, else: (_ -> nil))
  defp decode_ann(_), do: nil
end

OcrProbe.ColdLatencyCurve.run()
