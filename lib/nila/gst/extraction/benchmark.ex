defmodule Nila.Gst.Extraction.Benchmark do
  alias Nila.Gst.Purchase.Books
  alias Nila.Gst.Sales.Gstr1

  @providers %{
    "llama" => %{
      purchase: Nila.Gst.Extraction.Purchase.LlamaExtract,
      sales: Nila.Gst.Extraction.Sales.LlamaExtract
    },
    "mistral" => %{
      purchase: Nila.Gst.Extraction.Purchase.MistralOCR,
      sales: Nila.Gst.Extraction.Sales.MistralOCR
    }
  }

  def run(manifest_path, output_dir) do
    with {:ok, manifest} <- read_json(manifest_path),
         documents when is_list(documents) <- manifest["documents"] do
      File.mkdir_p!(output_dir)

      cases =
        Enum.map(documents, fn document ->
          run_case(document, manifest_path, output_dir)
        end)

      summary = %{
        "generated_at" => DateTime.utc_now(),
        "case_count" => length(cases),
        "false_clean_gate" => "requires human-reviewed expected values",
        "cases" => cases
      }

      File.write!(
        Path.join(output_dir, "summary.json"),
        Jason.encode_to_iodata!(summary, pretty: true)
      )

      {:ok, summary}
    else
      nil -> {:error, :manifest_missing_documents}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_case(document, manifest_path, output_dir) do
    name = Map.fetch!(document, "name")
    kind = benchmark_kind(Map.fetch!(document, "kind"))
    source_path = resolve_source(document["source"], manifest_path)
    content_type = document["content_type"] || content_type(source_path)
    bytes = File.read!(source_path)

    results =
      Map.new(@providers, fn {provider, modules} ->
        module = Map.fetch!(modules, kind)
        {provider, run_provider(module, kind, bytes, source_path, content_type, output_dir, name)}
      end)

    llama = results["llama"]
    mistral = results["mistral"]

    %{
      "name" => name,
      "kind" => to_string(kind),
      "source_sha256" => sha256(bytes),
      "source_byte_size" => byte_size(bytes),
      "providers" => results,
      "invoice_count_match" => llama["invoice_count"] == mistral["invoice_count"],
      "critical_diff_paths" =>
        diff_paths(critical(kind, llama["normalized"]), critical(kind, mistral["normalized"])),
      "normalized_diff_paths" => diff_paths(llama["normalized"], mistral["normalized"])
    }
  end

  defp run_provider(module, kind, bytes, source_path, content_type, output_dir, case_name) do
    started = System.monotonic_time()

    case module.extract(bytes,
           filename: Path.basename(source_path),
           content_type: content_type,
           on_progress: fn _stage -> :ok end
         ) do
      {:ok, result} ->
        duration_ms = elapsed_ms(started)
        normalized = normalize(kind, result.pages)
        audit = Map.get(result, :audit, %{})
        persist_output(output_dir, case_name, module.provider(), result, normalized)

        %{
          "status" => "succeeded",
          "model" => module.model(),
          "duration_ms" => duration_ms,
          "invoice_count" => length(normalized),
          "page_count" => audit[:source_page_count] || length(result.pages),
          "usage" => audit[:usage] || %{},
          "normalized" => normalized
        }

      {:error, reason, audit} ->
        persist_raw(output_dir, case_name, module.provider(), audit[:raw_response])
        failed(module, reason, started)

      {:error, reason} ->
        failed(module, reason, started)
    end
  end

  defp failed(module, reason, started) do
    %{
      "status" => "failed",
      "model" => module.model(),
      "duration_ms" => elapsed_ms(started),
      "error" => inspect(reason),
      "invoice_count" => 0,
      "page_count" => 0,
      "usage" => %{},
      "normalized" => []
    }
  end

  defp normalize(:purchase, pages) do
    pages
    |> Books.normalize()
    |> Map.fetch!("invoices")
    |> Enum.map(&Map.drop(&1, ["id", "pages", "images", "confidence", "source_attribution"]))
    |> Enum.sort_by(& &1["invoice_number"])
  end

  defp normalize(:sales, pages) do
    pages
    |> Enum.map(&Gstr1.normalize_invoice/1)
    |> Enum.map(
      &Map.drop(&1, ["page", "source_pages", "source_attribution", "image", "confidence"])
    )
    |> Enum.sort_by(& &1["invoice_number"])
  end

  defp persist_output(output_dir, case_name, provider, result, normalized) do
    case_dir = Path.join(output_dir, safe_name(case_name))
    File.mkdir_p!(case_dir)

    pages =
      Enum.map(result.pages, fn page ->
        Map.drop(page, ["image"])
      end)

    File.write!(
      Path.join(case_dir, "#{provider}_normalized.json"),
      Jason.encode_to_iodata!(normalized, pretty: true)
    )

    File.write!(
      Path.join(case_dir, "#{provider}_pages.json"),
      Jason.encode_to_iodata!(pages, pretty: true)
    )

    persist_raw(case_dir, provider, Map.get(result, :audit, %{})[:raw_response])
  end

  defp persist_raw(_output_dir, _case_name, _provider, nil), do: :ok

  defp persist_raw(output_dir, case_name, provider, raw_response) do
    case_dir = Path.join(output_dir, safe_name(case_name))
    File.mkdir_p!(case_dir)

    File.write!(
      Path.join(case_dir, "#{provider}_raw_response.json.zst"),
      :zstd.compress(raw_response)
    )
  end

  defp persist_raw(case_dir, provider, raw_response) do
    if raw_response do
      File.write!(
        Path.join(case_dir, "#{provider}_raw_response.json.zst"),
        :zstd.compress(raw_response)
      )
    end
  end

  defp diff_paths(left, right), do: diff_paths(left, right, "$", []) |> Enum.reverse()

  defp diff_paths(left, right, path, acc) when is_map(left) and is_map(right) do
    (Map.keys(left) ++ Map.keys(right))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce(acc, fn key, paths ->
      diff_paths(left[key], right[key], "#{path}.#{key}", paths)
    end)
  end

  defp diff_paths(left, right, path, acc) when is_list(left) and is_list(right) do
    max_length = max(length(left), length(right))

    if max_length == 0 do
      acc
    else
      Enum.reduce(0..(max_length - 1), acc, fn index, paths ->
        diff_paths(Enum.at(left, index), Enum.at(right, index), "#{path}[#{index}]", paths)
      end)
    end
  end

  defp diff_paths(left, right, _path, acc)
       when is_number(left) and is_number(right) and abs(left - right) < 0.001,
       do: acc

  defp diff_paths(value, value, _path, acc), do: acc
  defp diff_paths(_left, _right, path, acc), do: [path | acc]

  defp critical(:sales, invoices) do
    Enum.map(invoices, fn invoice ->
      %{
        "invoice_number" => invoice["invoice_number"],
        "invoice_date" => invoice["invoice_date"],
        "seller_gstin" => invoice["seller_gstin"],
        "buyer_gstin" => invoice["buyer_gstin"],
        "printed_total_taxable" => invoice["printed_total_taxable"],
        "printed_total_tax" => invoice["printed_total_tax"],
        "printed_grand_total" => invoice["printed_grand_total"],
        "line_items" =>
          Enum.map(invoice["line_items"] || [], fn line ->
            Map.take(line, [
              "hsn_sac",
              "quantity",
              "taxable_value",
              "cgst_rate",
              "cgst_amount",
              "sgst_rate",
              "sgst_amount",
              "igst_rate",
              "igst_amount"
            ])
          end)
      }
    end)
  end

  defp critical(:purchase, invoices) do
    Enum.map(invoices, fn invoice ->
      %{
        "invoice_number" => invoice["invoice_number"],
        "invoice_date" => invoice["invoice_date"],
        "vendor_gstin" => invoice["vendor_gstin"],
        "taxable_paise" => invoice["taxable_paise"],
        "tax_paise" => invoice["tax_paise"],
        "total_paise" => invoice["total_paise"],
        "line_items" =>
          Enum.map(invoice["line_items"] || [], fn line ->
            Map.take(line, ["hsn_sac", "quantity", "taxable_paise", "tax_paise"])
          end)
      }
    end)
  end

  defp resolve_source(source, manifest_path) do
    if Path.type(source) == :absolute do
      source
    else
      Path.expand(source, Path.dirname(manifest_path))
    end
  end

  defp read_json(path) do
    with {:ok, bytes} <- File.read(path), do: Jason.decode(bytes)
  end

  defp benchmark_kind("purchase"), do: :purchase
  defp benchmark_kind("sales"), do: :sales

  defp benchmark_kind(kind),
    do: raise(ArgumentError, "unsupported benchmark kind: #{inspect(kind)}")

  defp content_type(path) do
    case path |> Path.extname() |> String.downcase() do
      ".pdf" -> "application/pdf"
      ext when ext in [".jpg", ".jpeg"] -> "image/jpeg"
      ".png" -> "image/png"
      ".heic" -> "image/heic"
      _ -> "application/octet-stream"
    end
  end

  defp elapsed_ms(started) do
    System.monotonic_time()
    |> Kernel.-(started)
    |> System.convert_time_unit(:native, :millisecond)
  end

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  defp safe_name(name), do: String.replace(name, ~r/[^0-9A-Za-z_-]/, "_")
end
