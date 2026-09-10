defmodule Nila.Eval.SalesPdf do
  @moduledoc """
  Runs local sales PDFs through extraction, normalization, review and the real
  workings export without importing or approving business data. Each run gets
  a new directory. Raw responses and native text remain available for diagnosis.
  """

  alias Nila.Gst.Extraction.Sales.Vision
  alias Nila.Gst.Sales.{Gstr1, Review, Workings, WorkingsXlsx}

  def run(paths, client, period, opts \\ []) when is_list(paths) and paths != [] do
    dir = Keyword.get(opts, :output_root, "tmp/eval/sales-pdf")
    dir = Path.join(dir, Ecto.UUID.generate())
    File.mkdir_p!(dir)
    input = Keyword.get(opts, :input, :text)
    progress = Keyword.get(opts, :on_file, fn _summary -> :ok end)

    write!(dir, "manifest.json", %{
      client: client,
      period: period,
      input: input,
      created_at: DateTime.utc_now(),
      provider: Vision.provider(),
      model: Vision.model(),
      sources: Enum.map(paths, &%{path: Path.expand(&1), sha256: sha256(File.read!(&1))})
    })

    results =
      paths
      |> Enum.with_index(1)
      |> Enum.map(fn {path, ordinal} ->
        result = extract(path, ordinal, client, input, dir)
        progress.(Map.take(result, [:path, :status, :duration_ms, :error]))
        result
      end)

    invoices = Enum.flat_map(results, &Map.get(&1, :invoices, []))
    header = Gstr1.production_header(client.gstin, period)
    document_issues = Enum.flat_map(results, &document_issues/1)
    projection = Workings.materialize(invoices, [], header, document_issues)
    review = Review.build(projection)
    issues = projection.issues
    failures = Enum.filter(results, &(&1.status == "failed"))
    gating = Enum.filter(issues, &Nila.Gst.Issues.gating?/1)

    write!(dir, "invoices.json", invoices)
    write!(dir, "issues.json", issues)
    # This is explicitly a machine draft, never a reviewed/filing-ready return.
    write!(dir, "gstr1-draft.json", projection.derived)

    workbook =
      if invoices == [] do
        "no_invoices"
      else
        case WorkingsXlsx.build(projection, client, period, status: "Draft - unreviewed") do
          {:ok, bytes} ->
            File.write!(Path.join(dir, "workings.xlsx"), bytes)
            "written"

          {:error, reason} ->
            inspect(reason)
        end
      end

    summary = %{
      directory: dir,
      input: input,
      source_files: length(paths),
      extracted_files: length(results) - length(failures),
      invoice_count: length(invoices),
      active_invoice_count: length(projection.active_invoices),
      invoices_needing_review: length(review.needs_you),
      gating_issues: length(gating),
      reviewed: false,
      filing_ready: false,
      workbook: workbook,
      failures: Enum.map(failures, &Map.drop(&1, [:invoices]))
    }

    write!(dir, "summary.json", summary)
    {:ok, summary}
  end

  defp extract(path, ordinal, client, input, dir) do
    source_dir = Path.join(dir, String.pad_leading(to_string(ordinal), 3, "0"))
    File.mkdir_p!(source_dir)
    started = System.monotonic_time(:millisecond)

    per_call = fn metadata, call ->
      result = call.()

      case result do
        {:ok, %{audit: audit}} -> write!(source_dir, "#{metadata.stage}.json", audit)
        {:error, _reason, audit} -> write!(source_dir, "#{metadata.stage}.json", audit)
        _ -> :ok
      end

      result
    end

    result =
      Vision.extract(File.read!(path),
        filename: Path.basename(path),
        client_gstin: client.gstin,
        input: input,
        per_call: per_call
      )

    duration = System.monotonic_time(:millisecond) - started

    case result do
      {:ok, result} ->
        write!(source_dir, "extraction.json", Map.delete(result, :images))

        Enum.each(result.images, fn {name, bytes} ->
          File.write!(Path.join(source_dir, name), bytes)
        end)

        invoices =
          result.pages
          |> Enum.with_index(1)
          |> Enum.map(fn {artifact, index} ->
            artifact
            |> Gstr1.normalize_invoice()
            |> Map.put("id", "pdf_#{ordinal}_inv_#{index}")
            |> Map.put("source_filename", Path.basename(path))
          end)

        %{
          path: path,
          status: "ok",
          duration_ms: duration,
          invoices: invoices,
          excluded_documents: Map.get(result, :excluded_documents, []),
          unaccounted_pages: result.unaccounted_pages
        }

      {:error, reason} ->
        failure = %{path: path, status: "failed", duration_ms: duration, error: inspect(reason)}
        write!(source_dir, "failure.json", failure)
        failure
    end
  end

  defp document_issues(%{status: "ok", unaccounted_pages: []}), do: []

  defp document_issues(result) do
    source = Path.basename(result.path)

    detail =
      case result do
        %{status: "failed", error: error} ->
          "could not be extracted (#{error})"

        %{unaccounted_pages: pages} ->
          exclusions =
            result
            |> Map.get(:excluded_documents, [])
            |> Enum.map_join("; ", fn document ->
              "pages #{Enum.join(document["pages"], ", ")}: " <>
                "#{document["document_type"] || document["kind"]} (#{document["reason"]})"
            end)

          "has pages #{Enum.join(pages, ", ")} excluded from sales extraction: #{exclusions}"
      end

    [
      %{
        "invoice" => nil,
        "code" => "pages_unaccounted",
        "target" => "source:#{source}",
        "level" => Nila.Gst.Issues.level_for("pages_unaccounted"),
        "message" =>
          "#{source} #{detail}. Review the original and confirm no sales invoice is missing.",
        "fields" => ["doc_issue"]
      }
    ]
  end

  defp write!(dir, name, value),
    do: File.write!(Path.join(dir, name), Jason.encode!(value, pretty: true))

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
