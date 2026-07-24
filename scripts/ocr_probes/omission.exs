defmodule OcrProbe.Omission do
  @moduledoc false

  alias Nila.Gst.Extraction.Providers.Mistral

  @fixtures_root "test/fixtures/gstr1"

  @cases [
    {"breeze/2026-01", "breeze_jan_sales.pdf", "returns_012026_R1_33AEWPH4158J1Z3.json"},
    {"breeze/2026-05", "breeze_may_sales.pdf",
     "returns_06072026_R1_33AEWPH4158J1Z3_offline_others_0.json"},
    {"caltech/2025-10", "caltech_oct_sales.pdf", "returns_102025_R1_33BPBPK1081A1ZO.json"},
    {"caltech/2025-11", "caltech_nov_sales.pdf", "returns_112025_R1_33BPBPK1081A1ZO.json"},
    {"caltech/2025-12", "caltech_dec_sales.pdf", "returns_122025_R1_33BPBPK1081A1ZO.json"},
    {"caltech/2026-01", "caltech_jan_sales.pdf", "returns_012026_R1_33BPBPK1081A1ZO.json"}
  ]

  def run do
    out_dir = "tmp/mistral_omission_probe"
    File.mkdir_p!(out_dir)

    results = Enum.map(@cases, &probe(&1, out_dir))

    IO.puts("\n================ SUMMARY ================")

    Enum.each(results, fn r ->
      status = if r.missing == [] and r.extra == [], do: "OK", else: "MISMATCH"

      IO.puts(
        "#{status}  #{r.dir}  truth=#{r.truth_count} extracted=#{r.extracted_count}" <>
          "  missing=#{length(r.missing)} extra=#{length(r.extra)}"
      )

      if r.missing != [], do: IO.puts("    MISSING (in filed R1, not extracted): #{Enum.join(r.missing, ", ")}")
      if r.extra != [], do: IO.puts("    EXTRA (extracted, not in filed R1): #{Enum.join(r.extra, ", ")}")
    end)

    File.write!(Path.join(out_dir, "summary.json"), Jason.encode!(results, pretty: true))
    IO.puts("\nwrote #{Path.join(out_dir, "summary.json")}")
  end

  defp probe({dir, pdf, returns}, out_dir) do
    pdf_path = Path.join([@fixtures_root, dir, pdf])
    returns_path = Path.join([@fixtures_root, dir, returns])

    truth = filed_invoice_numbers(returns_path)
    bytes = File.read!(pdf_path)

    IO.puts("\n>>> #{dir}: whole-PDF OCR (no chunking), truth=#{length(truth)} invoices")
    started = System.monotonic_time(:millisecond)

    {extracted, note} =
      case Mistral.extract(:sales, bytes, filename: pdf) do
        {:ok, %{pages: pages}} ->
          {Enum.map(pages, &get_in(&1, ["data", "invoice_number"])), nil}

        {:error, reason} ->
          {[], inspect(reason)}

        {:error, reason, _audit} ->
          {[], inspect(reason)}
      end

    elapsed = System.monotonic_time(:millisecond) - started

    extracted_keys = extracted |> Enum.map(&norm/1) |> Enum.reject(&(&1 == "")) |> MapSet.new()
    truth_keys = truth |> Enum.map(&norm/1) |> MapSet.new()

    missing = truth |> Enum.reject(&(norm(&1) in extracted_keys)) |> Enum.sort()
    extra_keys = MapSet.difference(extracted_keys, truth_keys)

    extra =
      extracted
      |> Enum.filter(&(norm(&1) in extra_keys))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    IO.puts("    #{elapsed}ms  extracted #{length(extracted)} invoice entries#{if note, do: " ERROR=#{note}", else: ""}")

    result = %{
      dir: dir,
      elapsed_ms: elapsed,
      truth_count: length(truth),
      extracted_count: length(extracted),
      truth: Enum.sort(truth),
      extracted: Enum.sort(Enum.reject(extracted, &is_nil/1)),
      missing: missing,
      extra: extra,
      error: note
    }

    File.write!(
      Path.join(out_dir, String.replace(dir, "/", "_") <> ".json"),
      Jason.encode!(result, pretty: true)
    )

    result
  end

  defp filed_invoice_numbers(path) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> collect_inums([])
    |> Enum.uniq()
  end

  defp collect_inums(%{} = map, acc) do
    acc =
      case map do
        %{"inum" => inum} when is_binary(inum) -> [inum | acc]
        _ -> acc
      end

    Enum.reduce(map, acc, fn {_k, v}, a -> collect_inums(v, a) end)
  end

  defp collect_inums(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &collect_inums/2)

  defp collect_inums(_other, acc), do: acc

  defp norm(nil), do: ""
  defp norm(v), do: v |> to_string() |> String.upcase() |> String.replace(~r/[^0-9A-Z]/, "")
end

OcrProbe.Omission.run()
