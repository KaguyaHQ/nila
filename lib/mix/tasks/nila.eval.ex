defmodule Mix.Tasks.Nila.Eval do
  @shortdoc "Scores the GSTR-1 engine against filed returns"

  @moduledoc """
  The eval loop's command surface. Logic lives in `Nila.Eval`; this is arg
  parsing and printing, mirroring the `Nila.EvalCorpus` / `mix nila.eval_corpus`
  split.

      mix nila.eval extract <name>   # replay cached OCR through the retired text path
      mix nila.eval score <name>     # score the newest cached extraction
      mix nila.eval score --all

      mix nila.eval segment <name> [--runs 5] [--shape per_page|whole_dump] [--context neighbours|paper]
      mix nila.eval stability <name> [--runs 10] [--concurrency 4]
      mix nila.eval vision-schema <name> --pages 7 [--runs 3] [--source packet.pdf]
      mix nila.eval source-quality <name> [--transcription-attempt DIR]

  `extract` replays a historical cached transcription through the former
  segmented text path and writes a new attempt under `tmp/eval/segmented/`. Attempts are never
  overwritten because the model is non-deterministic and an overwritten attempt
  is a rewritten history.

  `score` replays the cached response bytes through mapping, verification,
  normalizing, deriving and diffing — all of which run at score time, so
  re-scoring after a rule change costs no API calls and no pure edit can hide
  behind a cache hit. It writes `fields.jsonl` and `report.md` under
  `tmp/eval/runs/<run_id>/`.

  Verdicts on rows the diff cannot settle live in `eval/adjudications/`; see
  `Nila.Eval.Adjudications`.
  """

  use Mix.Task

  alias Nila.Eval
  alias Nila.Gst.Extraction.Discovery
  alias Nila.Gst.Extraction.Transcription

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          all: :boolean,
          runs: :integer,
          shape: :string,
          context: :string,
          concurrency: :integer,
          pages: :string,
          source: :string,
          transcription_attempt: :string
        ]
      )

    if invalid != [], do: Mix.raise("invalid options #{inspect(invalid)}")

    validate_options!(positional, opts)

    if match?(["source-quality", _name], positional) do
      Mix.Task.run("compile")
    else
      Mix.Task.run("app.start")
    end

    case positional do
      ["extract", name] -> extract(name, opts)
      ["segment", name] -> segment(name, opts)
      ["stability", name] -> stability(name, opts)
      ["vision-schema", name] -> vision_schema(name, opts)
      ["source-quality", name] -> source_quality(name, opts)
      ["score", name] -> score_months([name], opts)
      ["score"] -> score_all(opts)
      [] -> Mix.shell().info(@moduledoc)
      other -> Mix.raise("unknown command #{inspect(Enum.join(other, " "))}")
    end
  end

  defp validate_options!(["source-quality", _name], opts) do
    reject_non_positive!(opts)

    if opts[:concurrency], do: Mix.raise("--concurrency applies only to stability")
    if opts[:runs], do: Mix.raise("--runs applies only to segment or stability")
  end

  defp validate_options!(["vision-schema", _name], opts) do
    reject_non_positive!(opts)
    if is_nil(opts[:pages]), do: Mix.raise("vision-schema requires --pages")
    if opts[:shape], do: Mix.raise("--shape does not apply to vision-schema")
    if opts[:context], do: Mix.raise("--context does not apply to vision-schema")
    if opts[:concurrency], do: Mix.raise("--concurrency does not apply to vision-schema")
  end

  defp validate_options!([command, _name], opts) when command in ~w(segment stability) do
    reject_non_positive!(opts)

    if opts[:transcription_attempt] do
      Mix.raise("--transcription-attempt applies only to source-quality")
    end

    if opts[:concurrency] && command != "stability" do
      Mix.raise("--concurrency applies only to stability")
    end
  end

  defp validate_options!(_positional, opts) do
    reject_non_positive!(opts)

    if opts[:transcription_attempt] do
      Mix.raise("--transcription-attempt applies only to source-quality")
    end

    if opts[:concurrency], do: Mix.raise("--concurrency applies only to stability")
    if opts[:runs], do: Mix.raise("--runs applies only to segment or stability")
  end

  defp reject_non_positive!(opts) do
    if opts[:runs] && opts[:runs] < 1, do: Mix.raise("--runs must be positive")

    if opts[:concurrency] && opts[:concurrency] < 1,
      do: Mix.raise("--concurrency must be positive")
  end

  # Segmentation on its own, scored against adjudicated boundaries and against
  # its own repeat runs. The stage split exists so a bad boundary and a bad read
  # are never the same number; the repeat runs exist because this decider was
  # picked once on one run of one packet and that is how the last three days
  # went wrong.
  defp segment(name, opts) do
    runs = opts[:runs] || 1
    shape = shape(opts)
    context = context(opts, shape)

    with {:ok, dir} <- Nila.Eval.Transcription.ensure(name),
         {:ok, transcription} <- Nila.Eval.Transcription.load(dir) do
      results =
        Enum.map(1..runs, fn index ->
          case Discovery.discover(transcription, shape: shape, context: context) do
            {:ok, result} ->
              if runs > 1, do: Mix.shell().info("run #{index}/#{runs}")
              print_segments(result)
              result

            {:error, reason} ->
              Mix.raise("segmentation failed: #{inspect(reason, limit: 8)}")
          end
        end)

      report_scores(name, shape, context, transcription, results)
    else
      {:error, reason} -> Mix.raise("segmentation failed: #{inspect(reason, limit: 8)}")
    end
  end

  defp shape(opts) do
    case opts[:shape] do
      nil -> :per_page
      "per_page" -> :per_page
      "whole_dump" -> :whole_dump
      other -> Mix.raise("unknown --shape #{inspect(other)} (per_page | whole_dump)")
    end
  end

  defp context(opts, :whole_dump) do
    case opts[:context] do
      nil -> :whole_dump
      context -> Mix.raise("--context #{context} applies only to --shape per_page")
    end
  end

  defp context(opts, :per_page) do
    case opts[:context] do
      nil -> :paper
      "neighbours" -> :neighbours
      "paper" -> :paper
      other -> Mix.raise("unknown --context #{inspect(other)} (neighbours | paper)")
    end
  end

  defp print_segments(%{segments: segments, violations: violations}) do
    Enum.each(segments, fn segment ->
      pages = Enum.map_join(segment.pages, ",", &to_string/1)

      Mix.shell().info(
        "  #{String.pad_trailing(pages, 12)} #{String.pad_trailing(to_string(segment.kind), 12)} " <>
          "#{String.pad_trailing(segment.invoice_no || "-", 20)} #{grounded(segment)}#{issues(segment)}"
      )
    end)

    Enum.each(violations, &Mix.shell().error("  violation: #{Discovery.describe(&1)}"))
    Mix.shell().info("")
  end

  defp report_scores(name, shape, context, transcription, results) do
    runs = Enum.map(results, & &1.segments)

    Mix.shell().info(
      "#{Transcription.page_count(transcription)} pages, #{length(runs)} run(s), shape #{shape}, context #{context}"
    )

    case Nila.Eval.Segmentation.truth(name) do
      {:ok, truth} ->
        Enum.each(runs, fn segments ->
          score = Nila.Eval.Segmentation.score(segments, truth)

          Mix.shell().info(
            "  boundary F1 #{score.boundary_f1}  (#{score.segments}/#{score.expected_segments} segments)  " <>
              "kind #{score.kind_accuracy}"
          )

          if score.invoices_dropped != [] do
            Mix.shell().error(
              "    invoices dropped as non-invoice: #{Enum.join(score.invoices_dropped, ",")}"
            )
          end

          if score.non_invoices_kept != [] do
            Mix.shell().info(
              "    non-invoices kept (cheap): #{Enum.join(score.non_invoices_kept, ",")}"
            )
          end
        end)

      {:error, {:no_truth, _name}} ->
        Mix.shell().info("  no adjudicated boundaries in eval/segmentation/#{name}.json")
    end

    if length(runs) > 1 do
      rates = Nila.Eval.Segmentation.agreement_rates(runs)

      Mix.shell().info(
        "  stability: rand #{Float.round(Nila.Eval.Segmentation.stability(runs), 3)}  " <>
          "identical #{rates.identical}  kind agreement #{rates.kind_agreement}"
      )
    end

    case Nila.Eval.Segmentation.repairs(runs) do
      repairs when repairs == %{} -> Mix.shell().info("  guards: silent")
      repairs -> Mix.shell().info("  guards: #{inspect(repairs, charlists: :as_lists)}")
    end
  end

  defp grounded(%{grounded?: true}), do: "grounded"
  defp grounded(%{grounded?: false}), do: "NOT ON PAGE"
  defp grounded(_segment), do: ""

  defp issues(%{issues: []}), do: ""
  defp issues(%{issues: issues}), do: "  " <> inspect(issues, limit: 5, charlists: :as_lists)

  defp stability(name, opts) do
    runs = opts[:runs] || 10
    concurrency = opts[:concurrency] || 4
    shape = shape(opts)
    context = context(opts, shape)

    Mix.shell().info(
      "testing #{name}: #{runs} extraction runs, concurrency #{concurrency}, fixed OCR and boundaries"
    )

    report = fn
      {:transcribed, pages} ->
        Mix.shell().info("  cached transcription: #{pages} pages")

      {:segmented, segments, violations} ->
        invoices = Enum.count(segments, &(&1.kind == :invoice))
        Mix.shell().info("  fixed boundaries: #{invoices} invoices")
        Enum.each(violations, &Mix.shell().error("  violation: #{Discovery.describe(&1)}"))

      {:stability_run, index, total, run} ->
        slowest = run["calls"] |> Enum.map(& &1["duration_ms"]) |> Enum.max(fn -> 0 end)

        Mix.shell().info(
          "  run #{index}/#{total}: batch #{run["duration_ms"]}ms, slowest call #{slowest}ms"
        )

      {:stability_failure, index, total, failure} ->
        Mix.shell().error("  run #{index}/#{total}: FAILED #{failure["reason"]}")
    end

    case Nila.Eval.Segmented.stability(name,
           runs: runs,
           max_concurrency: concurrency,
           shape: shape,
           context: context,
           on_event: report
         ) do
      {:ok, result} ->
        print_stability(result)

      {:error, reason} ->
        Mix.raise("stability run failed: #{inspect(reason, limit: 10)}")
    end
  end

  defp vision_schema(name, opts) do
    runs = opts[:runs] || 3
    pages = parse_pages!(opts[:pages])

    Mix.shell().info(
      "testing production vision schema on #{name}, pages #{Enum.join(pages, ",")}, #{runs} run(s)"
    )

    run_opts = [runs: runs] |> maybe_put(:source, opts[:source])
    {:ok, report} = Nila.Eval.VisionSchema.run(name, pages, run_opts)

    Enum.each(report["results"], fn result ->
      if result["status"] == "ok" do
        Mix.shell().info(
          "  run #{result["run"]}/#{runs}: #{result["line_count"]} lines, " <>
            "taxable #{result["taxable_total"]}, tax #{result["tax_total"]}"
        )
      else
        Mix.shell().error("  run #{result["run"]}/#{runs}: FAILED #{result["error"]}")
      end
    end)

    Mix.shell().info("\nraw responses and report → #{report["dir"]}")
  end

  defp parse_pages!(value) do
    pages =
      value
      |> String.split(",", trim: true)
      |> Enum.map(fn page ->
        case Integer.parse(String.trim(page)) do
          {number, ""} when number > 0 -> number
          _invalid -> Mix.raise("invalid --pages #{inspect(value)}; use 7 or 7,8")
        end
      end)

    if pages == Enum.sort(Enum.uniq(pages)),
      do: pages,
      else: Mix.raise("--pages must be unique and ascending")
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp print_stability(result) do
    batch = result["latency_ms"]["batch"]
    call = result["latency_ms"]["call"]

    Mix.shell().info("")
    print_latency("batch", batch)
    print_latency("call ", call)

    Mix.shell().info(
      "outputs: #{result["unique_output_sets"]} unique set(s) across " <>
        "#{result["successful_runs"]}/#{result["requested_runs"]} successful runs"
    )

    Enum.each(result["invoices"], fn invoice ->
      status =
        case invoice["stable"] do
          true -> "stable"
          false -> "UNSTABLE"
          nil -> "one run"
        end

      variants = invoice["variants"]

      changed =
        variants
        |> Enum.filter(fn {_field, values} -> length(values) > 1 end)
        |> Enum.map_join(", ", &elem(&1, 0))

      changed = if changed == "", do: "", else: "; changed #{changed}"

      Mix.shell().info(
        "  pages #{invoice["segment_key"]}: #{status}; " <>
          "invoice #{inspect(variants["invoice_number"])}; lines #{inspect(variants["line_count"])}; " <>
          "buyer GSTIN #{inspect(variants["buyer_gstin"])}#{changed}"
      )
    end)

    Mix.shell().info("\nraw responses and report → #{result["dir"]}")
  end

  defp print_latency(label, nil), do: Mix.shell().info("#{label} ms: no successful calls")

  defp print_latency(label, latency) do
    Mix.shell().info(
      "#{label} ms: min #{latency["min"]}  p50 #{latency["p50"]}  " <>
        "p95 #{latency["p95"]}  max #{latency["max"]}"
    )
  end

  defp extract(name, opts) do
    shape = shape(opts)
    context = context(opts, shape)
    Mix.shell().info("extracting #{name} (segmented, #{shape}, #{context})")

    report = fn
      {:transcribed, pages} ->
        Mix.shell().info("  transcribed #{pages} pages")
        :ok

      {:segmented, segments, violations} ->
        Mix.shell().info(
          "  #{length(segments)} segments, #{Enum.count(segments, &(&1.kind == :invoice))} invoices"
        )

        Enum.each(violations, &Mix.shell().error("  violation: #{Discovery.describe(&1)}"))
        :ok

      {:segment, done, total} ->
        Mix.shell().info("  #{done}/#{total} extracted")
        :ok
    end

    case Nila.Eval.Segmented.run(name, on_event: report, shape: shape, context: context) do
      {:ok, dir} -> Mix.shell().info("\ncached → #{dir}")
      {:error, reason} -> Mix.raise("segmented extraction failed: #{inspect(reason, limit: 8)}")
    end
  end

  defp source_quality(name, opts) do
    case Nila.Eval.SourceQuality.report(name, opts) do
      {:ok, report} ->
        Mix.shell().info("source quality #{name}")
        Mix.shell().info("  cached attempt: #{report.attempt}")
        Mix.shell().info("")
        Mix.shell().info("page  provider   all-word   p10       <70       words")

        Enum.each(report.pages, fn page ->
          Mix.shell().info(
            "#{page["page"] |> to_string() |> String.pad_leading(4)}  " <>
              "#{percentage(page["provider_average_confidence_score"])}  " <>
              "#{percentage(page["all_word_average_confidence_score"])}  " <>
              "#{percentage(page["all_word_p10_confidence_score"])}  " <>
              "#{percentage(page["under_70_word_share"])}  " <>
              "#{page["all_word_count"] |> to_string() |> String.pad_leading(5)}"
          )
        end)

      {:error, reason} ->
        Mix.raise("source-quality report failed: #{inspect(reason, limit: 8)}")
    end
  end

  defp percentage(nil), do: String.pad_leading("-", 8)

  defp percentage(value) do
    value
    |> Kernel.*(100.0)
    |> :erlang.float_to_binary(decimals: 2)
    |> Kernel.<>("%")
    |> String.pad_leading(8)
  end

  defp score_all(opts) do
    opts[:all] || Mix.raise("mix nila.eval score needs <name>, or --all for every month")
    score_months(Eval.evaluable(), opts)
  end

  defp score_months(names, opts) do
    run_id = Eval.run_id()
    shape = shape(opts)
    context = context(opts, shape)
    Mix.shell().info("run #{run_id} (segmented, #{shape}, #{context})\n")

    Enum.each(names, fn name ->
      case Eval.score(name, run_id, shape: shape, context: context) do
        {:ok, month} ->
          Mix.shell().info("  #{String.pad_trailing(name, 26)} #{summary(month)}")
          warn_unaccounted(month)

        {:error, reason} ->
          Mix.shell().error("  #{String.pad_trailing(name, 26)} #{inspect(reason, limit: 6)}")
      end
    end)
  end

  defp summary(month) do
    "#{month.raw["score"]}%#{adjusted(month)}  #{length(month.mismatches)} mismatches across " <>
      "#{length(month.by_invoice)} invoices  → #{month.report_path}"
  end

  defp adjusted(%{adjusted: nil}), do: ""
  defp adjusted(%{adjusted: adjusted}), do: " raw / #{adjusted["score"]}% adjusted"

  # A page no artifact claimed is an extraction gap, so it is said out loud
  # here rather than only in the run record.
  defp warn_unaccounted(month) do
    case month.provenance["unaccounted_pages"] do
      pages when is_list(pages) and pages != [] ->
        Mix.shell().error("        unaccounted pages: #{inspect(pages)}")

      _none ->
        :ok
    end
  end
end
