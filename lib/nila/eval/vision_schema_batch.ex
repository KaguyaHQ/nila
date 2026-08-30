defmodule Nila.Eval.VisionSchemaBatch do
  @moduledoc """
  Repeats production direct-vision extraction over adjudicated invoice boundaries.

  Discovery is deliberately absent: a schema experiment should measure invoice
  reading, not a fresh set of model-chosen page boundaries. Every run retains its
  raw responses, expanded artifacts, summary, and extraction fingerprint.
  """

  alias Nila.Eval.Segmentation
  alias Nila.EvalCorpus
  alias Nila.Gst.Extraction.Providers.OpenAICompatibleChat
  alias Nila.Gst.Extraction.Segmented
  alias Nila.Gst.Extraction.VisionPipeline

  @root "tmp/eval/vision-schema-batch"

  def run(name, opts \\ []) when is_binary(name) do
    runs = Keyword.get(opts, :runs, 2)
    concurrency = Keyword.get(opts, :max_concurrency, 4)
    doc = EvalCorpus.document!(name)
    kind = kind!(doc)
    source = EvalCorpus.fetch!(name)
    bytes = File.read!(source)
    {:ok, truth} = Segmentation.truth(name)
    :ok = verify_truth!(doc, truth)
    page_groups = invoice_page_groups(truth)
    dir = Path.join([@root, name, attempt_id()])

    File.mkdir_p!(Path.join(dir, "runs"))

    manifest = %{
      "document" => name,
      "source_sha256" => sha256(bytes),
      "page_groups" => page_groups,
      "page_groups_sha256" => sha256(Jason.encode!(page_groups)),
      "runs" => runs,
      "max_concurrency" => concurrency,
      "created_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "extraction" =>
        OpenAICompatibleChat.fingerprint(Segmented.prompt(kind), Segmented.schema(kind))
    }

    write_json!(Path.join(dir, "manifest.json"), manifest)

    results =
      Enum.map(1..runs, fn index ->
        started = System.monotonic_time(:millisecond)

        result =
          VisionPipeline.extract_fixed_segments(kind, bytes, page_groups,
            filename: Path.basename(source),
            client_gstin: client_gstin!(doc["client"]),
            max_concurrency: concurrency
          )

        duration = System.monotonic_time(:millisecond) - started
        save_run!(dir, index, duration, result)
      end)

    report = %{"dir" => dir, "manifest" => manifest, "results" => results}
    write_json!(Path.join(dir, "report.json"), report)
    {:ok, report}
  end

  defp save_run!(dir, index, duration, {:ok, result}) do
    run_dir = Path.join([dir, "runs", pad(index)])
    File.mkdir_p!(run_dir)
    File.write!(Path.join(run_dir, "raw_response.json"), result.audit.raw_response)

    artifact_result =
      result
      |> Map.delete(:images)
      |> update_in([:audit], &Map.delete(&1, :raw_response))

    write_json!(Path.join(run_dir, "artifact.json"), artifact_result)

    invoices = Enum.map(result.pages, &invoice_summary/1)

    summary = %{
      "run" => index,
      "status" => "ok",
      "duration_ms" => duration,
      "invoice_count" => length(invoices),
      "flagged_count" => Enum.count(invoices, &(&1["verification_status"] == "flagged")),
      "unverifiable_count" =>
        Enum.count(invoices, &(&1["verification_status"] == "unverifiable")),
      "line_count" => Enum.sum(Enum.map(invoices, & &1["line_count"])),
      "invoices" => invoices
    }

    write_json!(Path.join(run_dir, "summary.json"), summary)
    summary
  end

  defp save_run!(dir, index, duration, {:error, reason}) do
    run_dir = Path.join([dir, "runs", pad(index)])
    File.mkdir_p!(run_dir)

    summary = %{
      "run" => index,
      "status" => "failed",
      "duration_ms" => duration,
      "error" => inspect(reason, limit: 20, printable_limit: 2_000)
    }

    write_json!(Path.join(run_dir, "summary.json"), summary)
    summary
  end

  defp invoice_summary(artifact) do
    data = artifact["data"]
    lines = data["line_items"] || []

    %{
      "pages" => artifact["source_pages"],
      "invoice_number" => data["invoice_number"],
      "line_count" => length(lines),
      "printed_total_taxable" => data["printed_total_taxable"],
      "printed_total_tax" => data["printed_total_tax"],
      "printed_grand_total" => data["printed_grand_total"],
      "printed_tax_components" => Enum.map(lines, & &1["printed_tax_components"]),
      "canonical_tax_heads" => Enum.map(lines, &canonical_heads/1),
      "tax_component_issues" => Enum.flat_map(lines, &(&1["tax_component_issues"] || [])),
      "verification_status" => artifact["verification"]["status"],
      "verification_flags" => artifact["verification"]["flags"]
    }
  end

  defp canonical_heads(line) do
    ~w(cgst sgst igst)
    |> Enum.filter(fn head -> line["#{head}_rate"] != nil or line["#{head}_amount"] != nil end)
    |> Enum.map(&String.upcase/1)
  end

  defp invoice_page_groups(truth) do
    truth["segments"]
    |> Enum.filter(&(&1["kind"] == "invoice"))
    |> Enum.map(& &1["pages"])
  end

  defp verify_truth!(doc, truth) do
    cond do
      truth["document"] != doc["name"] ->
        raise "segmentation truth names #{truth["document"]}, expected #{doc["name"]}"

      truth["pages"] != doc["pages"] ->
        raise "segmentation truth has #{truth["pages"]} pages, expected #{doc["pages"]}"

      true ->
        :ok
    end
  end

  defp client_gstin!(client) do
    Enum.find_value(EvalCorpus.clients(), fn {gstin, name} -> if name == client, do: gstin end) ||
      raise "no corpus GSTIN for #{client}"
  end

  defp kind!(%{"kind" => "sales"}), do: :sales
  defp kind!(%{"kind" => "purchase"}), do: :purchase
  defp kind!(doc), do: raise("unsupported corpus kind #{inspect(doc["kind"])}")

  defp attempt_id do
    DateTime.utc_now()
    |> DateTime.to_iso8601(:extended)
    |> String.replace(~r/[^0-9A-Za-z.-]/, "-")
  end

  defp pad(value), do: value |> to_string() |> String.pad_leading(2, "0")
  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  defp write_json!(path, value), do: File.write!(path, Jason.encode!(value, pretty: true))
end
