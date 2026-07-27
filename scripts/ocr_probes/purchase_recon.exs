defmodule OcrProbe.PurchaseRecon do
  @moduledoc """
  Reconcile windowed extraction of a purchase packet against the filed GSTR-2B.

  2B is a lower bound, not exact truth: it lists what *suppliers* filed. So the
  two directions mean different things:

    - 2B line with no extracted bill → extraction miss OR the bill never made
      it into the shoebox — a human settles which (check unaccounted pages first).
    - extracted bill with no 2B line → expected for unregistered sellers / RCM /
      non-filing vendors; in the product this is the ITC-at-risk chase list.

      mix run scripts/ocr_probes/purchase_recon.exs                    # all evaluable purchase months
      mix run scripts/ocr_probes/purchase_recon.exs caltech-2026-04-purchase
  """

  alias Nila.Gst.Extraction.Windowed

  def run(names) do
    docs =
      Nila.EvalCorpus.documents()
      |> Enum.filter(&(&1["kind"] == "purchase" and gstr2b?(&1["ground_truth"])))
      |> then(fn docs ->
        case names do
          [] -> docs
          _ -> Enum.filter(docs, &(&1["name"] in names))
        end
      end)

    if docs == [], do: Mix.raise("no evaluable purchase documents matched (need 2B ground truth)")

    out_dir = "tmp/purchase_recon_probe"
    File.mkdir_p!(out_dir)
    Enum.each(docs, &recon(&1, out_dir))
  end

  defp gstr2b?(nil), do: false
  defp gstr2b?(path), do: String.contains?(Path.basename(path), "R2B")

  defp recon(doc, out_dir) do
    IO.puts("\n>>> #{doc["name"]}  (#{doc["pages"]}p, truth: #{Path.basename(doc["ground_truth"])})")

    bytes = doc["name"] |> Nila.EvalCorpus.fetch!() |> File.read!()
    started = System.monotonic_time(:millisecond)
    {:ok, result} = Windowed.extract(:purchase, bytes, filename: Path.basename(doc["key"]))
    elapsed = System.monotonic_time(:millisecond) - started

    extracted =
      Enum.map(result.pages, fn a ->
        %{
          inum: get_in(a, ["data", "invoice_number"]),
          gstin: get_in(a, ["data", "seller", "gstin"]),
          seller: get_in(a, ["data", "seller", "name"]),
          total: get_in(a, ["data", "printed_grand_total"]),
          pages: a["source_pages"]
        }
      end)

    truth = gstr2b_lines(doc["ground_truth"])
    truth_by_key = Map.new(truth, &{norm(&1.inum), &1})
    extracted_keys = MapSet.new(extracted, &norm(&1.inum))

    matched = Enum.filter(extracted, &Map.has_key?(truth_by_key, norm(&1.inum)))
    not_in_2b = Enum.reject(extracted, &Map.has_key?(truth_by_key, norm(&1.inum)))
    missing = Enum.reject(truth, &(norm(&1.inum) in extracted_keys))

    IO.puts("    #{elapsed}ms  extracted=#{length(extracted)}  2B lines=#{length(truth)}")
    IO.puts("    matched=#{length(matched)}  missing-vs-2B=#{length(missing)}  not-in-2B=#{length(not_in_2b)}")

    if result.unaccounted_pages != [],
      do: IO.puts("    unaccounted pages: #{inspect(result.unaccounted_pages)}")

    Enum.each(matched, fn e ->
      t = truth_by_key[norm(e.inum)]
      value_note = if values_close?(e.total, t.value), do: "", else: "  VALUE MISMATCH extracted=#{e.total} 2B=#{t.value}"
      gstin_note = if norm(e.gstin) == norm(t.gstin), do: "", else: "  GSTIN MISMATCH extracted=#{e.gstin} 2B=#{t.gstin}"
      IO.puts("    ok    #{pad(e.inum)} #{t.supplier}#{value_note}#{gstin_note}")
    end)

    Enum.each(missing, fn t ->
      IO.puts("    MISS  #{pad(t.inum)} #{t.supplier}  ₹#{t.value}  (in 2B, not extracted — shoebox gap or pipeline miss)")
    end)

    Enum.each(not_in_2b, fn e ->
      IO.puts("    chase #{pad(e.inum)} #{e.seller}  ₹#{inspect(e.total)}  p#{inspect(e.pages, charlists: :as_lists)}  (extracted, vendor has not filed)")
    end)

    File.write!(
      Path.join(out_dir, doc["name"] <> ".json"),
      Jason.encode!(
        %{
          document: doc["name"],
          elapsed_ms: elapsed,
          unaccounted_pages: result.unaccounted_pages,
          matched: length(matched),
          missing_vs_2b: missing,
          not_in_2b: not_in_2b
        },
        pretty: true
      )
    )
  end

  defp gstr2b_lines(path) do
    doc = path |> File.read!() |> Jason.decode!() |> then(&(&1["data"] || &1))

    for supplier <- get_in(doc, ["docdata", "b2b"]) || [],
        inv <- supplier["inv"] || [] do
      %{
        inum: inv["inum"],
        gstin: supplier["ctin"],
        supplier: supplier["trdnm"],
        value: inv["val"],
        date: inv["dt"]
      }
    end
  end

  defp values_close?(nil, _), do: false
  defp values_close?(extracted, filed) when is_number(extracted) and is_number(filed),
    do: abs(extracted - filed) <= 1.0

  defp values_close?(_, _), do: false

  defp norm(nil), do: ""
  defp norm(v), do: v |> to_string() |> String.upcase() |> String.replace(~r/[^0-9A-Z]/, "")

  defp pad(v), do: String.pad_trailing(to_string(v), 20)
end

OcrProbe.PurchaseRecon.run(System.argv())
