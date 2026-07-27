defmodule Mix.Tasks.Nila.BenchmarkOcr do
  use Mix.Task

  @shortdoc "Benchmarks Mistral OCR against LlamaExtract"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, names, invalid} =
      OptionParser.parse(args,
        strict: [output: :string],
        aliases: [o: :output]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    output = opts[:output] || Path.join("tmp/benchmark_ocr", timestamp())

    case Nila.Gst.Extraction.Benchmark.run(names, Path.expand(output)) do
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
