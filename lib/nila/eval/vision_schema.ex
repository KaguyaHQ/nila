defmodule Nila.Eval.VisionSchema do
  @moduledoc """
  Repeats the exact production direct-vision invoice request on fixed pages.

  Each attempt records the schema fingerprint, expanded artifact, summary, and
  raw provider response. Run the same command before and after a schema edit to
  compare behaviour without rebuilding temporary scripts or changing intake data.
  """

  alias Nila.EvalCorpus
  alias Nila.Gst.Extraction.LineAmounts
  alias Nila.Gst.Extraction.Providers.OpenAICompatibleChat
  alias Nila.Gst.Extraction.{InvoicePrompt, InvoiceSchema}
  alias Nila.Gst.Extraction.VisionPipeline

  @root "tmp/eval/vision-schema"

  def run(name, pages, opts \\ []) when is_binary(name) and is_list(pages) do
    runs = Keyword.get(opts, :runs, 3)
    doc = EvalCorpus.document!(name)
    kind = kind!(doc)
    source = Keyword.get(opts, :source) || EvalCorpus.fetch!(name)
    bytes = File.read!(source)
    verify_source!(doc, bytes, source)
    client_gstin = client_gstin!(doc["client"])
    dir = Path.join([@root, name, attempt_id()])

    File.mkdir_p!(Path.join(dir, "runs"))

    manifest = %{
      "document" => name,
      "source_sha256" => sha256(bytes),
      "pages" => pages,
      "runs" => runs,
      "created_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "extraction" =>
        OpenAICompatibleChat.fingerprint(
          InvoicePrompt.direct(kind, [], :vision),
          InvoiceSchema.tuple_schema(kind)
        )
    }

    write_json!(Path.join(dir, "manifest.json"), manifest)

    results =
      Enum.map(1..runs, fn index ->
        started = System.monotonic_time(:millisecond)

        result =
          VisionPipeline.extract_fixed_segments(kind, bytes, [pages],
            filename: Path.basename(source),
            client_gstin: client_gstin
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

    [artifact] = result.pages
    lines = artifact["data"]["line_items"]

    summary = %{
      "run" => index,
      "status" => "ok",
      "duration_ms" => duration,
      "invoice_number" => artifact["data"]["invoice_number"],
      "line_count" => length(lines),
      "taxable_total" => sum_taxable(lines),
      "tax_total" => sum_tax(lines),
      "printed_tax" => artifact["data"]["printed_total_tax"],
      "printed_grand_total" => artifact["data"]["printed_grand_total"],
      "line_amounts" => Enum.map(lines, & &1["printed_line_amount"]),
      "verification_flags" => artifact["verification"]["flags"]
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

  defp sum_taxable(lines) do
    lines
    |> Enum.map(&(LineAmounts.taxable_value(&1) || 0))
    |> Enum.sum()
    |> round_money()
  end

  defp sum_tax(lines) do
    lines
    |> Enum.map(fn line ->
      (line["cgst_amount"] || 0) + (line["sgst_amount"] || 0) + (line["igst_amount"] || 0)
    end)
    |> Enum.sum()
    |> round_money()
  end

  defp round_money(value) when is_integer(value), do: value
  defp round_money(value) when is_float(value), do: Float.round(value, 2)

  defp client_gstin!(client) do
    Enum.find_value(EvalCorpus.clients(), fn {gstin, name} -> if name == client, do: gstin end) ||
      raise "no corpus GSTIN for #{client}"
  end

  defp verify_source!(doc, bytes, source) do
    actual = sha256(bytes)

    if actual != doc["sha256"] do
      raise "source #{source} has SHA-256 #{actual}, expected #{doc["sha256"]} for #{doc["name"]}"
    end
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
