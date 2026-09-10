defmodule Nila.TallySalesWorkingsBenchmark do
  @moduledoc """
  Reads a Tally-exported PDF through production discovery/extraction, then replays
  the extracted artifacts through sales workings. Never connects or writes to Tally.

      mix run --no-start eval/benchmarks/tally_sales_workings.exs extract FIXTURE_DIR
      mix run --no-start eval/benchmarks/tally_sales_workings.exs score FIXTURE_DIR RUN_DIR
      mix run --no-start eval/benchmarks/tally_sales_workings.exs score FIXTURE_DIR RUN_DIR REVIEW_JSON

  FIXTURE_DIR contains manifest.json and native-gstr1.json. The source PDF is
  fetched from the private eval corpus using manifest.json's corpus_document.
  Each extraction
  gets a new directory under tmp/tally-sales-workings; scoring makes no model calls.
  Review issues and field mismatches are retained, including HSN/document summaries.
  """

  alias Nila.Eval.Gstr1Diff
  alias Nila.Gst.Extraction.Providers.OpenAICompatibleChatFinch
  alias Nila.Gst.Extraction.Sales.Extractor
  alias Nila.Gst.Extraction.Sales.Normalizer
  alias Nila.Gst.Sales.{Gstr1, Workings}

  def run(["extract", fixture_dir]) do
    {:ok, _} = Application.ensure_all_started(:finch)
    {:ok, _} = Application.ensure_all_started(:ex_aws)
    {:ok, _} = Application.ensure_all_started(:req)

    {:ok, _} =
      Finch.start_link(
        name: OpenAICompatibleChatFinch,
        pools: %{OpenAICompatibleChatFinch.origin() => OpenAICompatibleChatFinch.pool_options()}
      )

    id = DateTime.utc_now() |> DateTime.to_iso8601() |> String.replace(":", "-")
    run_dir = Path.join("tmp/tally-sales-workings", id)
    configure_storage(run_dir)
    fixture = read_json(Path.join(fixture_dir, "manifest.json"))
    path = Nila.EvalCorpus.fetch!(Map.fetch!(fixture, "corpus_document"))
    bytes = File.read!(path)
    expected = read_json(Path.join(fixture_dir, "native-gstr1.json"))

    put_json("manifest.json", %{
      corpus_document: fixture["corpus_document"],
      source_sha256: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower),
      provider: Extractor.provider(),
      model: Extractor.model(),
      expected_sha256:
        :crypto.hash(:sha256, File.read!(Path.join(fixture_dir, "native-gstr1.json")))
        |> Base.encode16(case: :lower)
    })

    {:ok, result} =
      Extractor.extract(bytes,
        filename: "sales-packet.pdf",
        client_gstin: expected["gstin"],
        max_concurrency: 4,
        on_progress: &IO.inspect(&1, label: "extraction")
      )

    put_json("extraction.json", Map.delete(result, :images))
    score(fixture_dir, run_dir)
    IO.puts("Run: #{Path.expand(run_dir)}")
  end

  def run(["score", fixture_dir, run_dir]), do: score(fixture_dir, run_dir)
  def run(["score", fixture_dir, run_dir, review]), do: score(fixture_dir, run_dir, review)
  def run(_), do: raise(ArgumentError, @moduledoc)

  defp score(fixture_dir, run_dir, review_path \\ nil) do
    configure_storage(run_dir)
    extraction = read_json(Path.join(run_dir, "extraction.json"))
    expected = read_json(Path.join(fixture_dir, "native-gstr1.json"))
    invoices = Enum.map(extraction["pages"], &Normalizer.normalize/1)
    review = if review_path, do: read_json(review_path), else: []
    prefix = if review_path, do: "reviewed-", else: ""
    workings = Workings.materialize(invoices, review, Map.take(expected, ["gstin", "fp"]))
    diff = Gstr1Diff.diff(workings.derived, expected)

    put_json(
      prefix <> "workings.json",
      Map.take(workings, [:invoices, :issues, :derived, :silent_errors])
    )

    put_json(prefix <> "diff.json", diff)
    if review_path, do: put_json(prefix <> "resolutions.json", review)

    IO.inspect(
      %{
        invoices: length(invoices),
        unaccounted_pages: extraction["unaccounted_pages"],
        classifications:
          Enum.map(workings.invoices, &{&1["invoice_number"], Gstr1.filing_table(&1)}),
        review_issues: Enum.map(workings.issues, &Map.take(&1, ~w(invoice code level))),
        silent_errors: workings.silent_errors,
        score: diff["score"],
        mismatches: diff["mismatches"]
      },
      limit: :infinity
    )
  end

  defp configure_storage(root) do
    Application.put_env(:nila, Nila.Storage,
      adapter: Nila.Storage.Local,
      root: Path.expand(root),
      public_path: "/unused-eval"
    )
  end

  defp read_json(path), do: path |> File.read!() |> Jason.decode!()

  defp put_json(key, value) do
    {:ok, _} = Nila.Storage.put(key, Jason.encode!(value, pretty: true))
  end
end

Nila.TallySalesWorkingsBenchmark.run(System.argv())
