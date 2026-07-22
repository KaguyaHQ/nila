defmodule Mix.Tasks.Nila.BenchmarkOcr do
  use Mix.Task

  @shortdoc "Benchmarks Mistral OCR against LlamaExtract"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _rest, invalid} =
      OptionParser.parse(args,
        strict: [manifest: :string, output: :string],
        aliases: [m: :manifest, o: :output]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    manifest = opts[:manifest] || "bench/ocr/manifest.json"
    output = opts[:output] || Path.join("bench/ocr/results", timestamp())

    case Nila.Gst.ExtractorBenchmark.run(Path.expand(manifest), Path.expand(output)) do
      {:ok, summary} ->
        failures =
          summary["cases"]
          |> Enum.count(fn benchmark_case ->
            Enum.any?(benchmark_case["providers"], fn {_provider, result} ->
              result["status"] != "succeeded"
            end)
          end)

        mismatches = Enum.count(summary["cases"], &(&1["critical_diff_paths"] != []))

        Mix.shell().info(
          "OCR benchmark complete: #{summary["case_count"]} cases, #{failures} provider failures, #{mismatches} critical mismatches\nResults: #{Path.expand(output)}"
        )

      {:error, reason} ->
        Mix.raise("OCR benchmark failed: #{inspect(reason)}")
    end
  end

  defp timestamp do
    DateTime.utc_now()
    |> Calendar.strftime("%Y%m%dT%H%M%SZ")
  end
end
