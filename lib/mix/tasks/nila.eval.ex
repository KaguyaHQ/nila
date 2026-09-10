defmodule Mix.Tasks.Nila.Eval do
  @shortdoc "Runs invoice extraction experiments"
  @moduledoc """
  Runs the current vision reader on fixed invoice pages.

      mix nila.eval vision-schema <name> --pages 7 [--runs 3] [--source packet.pdf]
      mix nila.eval vision-schema-batch <name> [--runs 2] [--concurrency 4]

  For PDF-text and whole-document evaluations, use `mix nila.eval_sales_pdf`.
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [runs: :integer, concurrency: :integer, pages: :string, source: :string]
      )

    if invalid != [], do: Mix.raise("invalid options #{inspect(invalid)}")

    for key <- [:runs, :concurrency], opts[key] && opts[key] < 1 do
      Mix.raise("--#{key} must be positive")
    end

    case positional do
      ["vision-schema", name] ->
        if is_nil(opts[:pages]), do: Mix.raise("vision-schema requires --pages")
        if opts[:concurrency], do: Mix.raise("--concurrency applies only to vision-schema-batch")
        Mix.Task.run("app.start")
        vision_schema(name, opts)

      ["vision-schema-batch", name] ->
        if opts[:pages] || opts[:source],
          do: Mix.raise("--pages and --source apply only to vision-schema")

        Mix.Task.run("app.start")
        vision_schema_batch(name, opts)

      [] ->
        Mix.shell().info(@moduledoc)

      other ->
        Mix.raise("unknown command #{inspect(Enum.join(other, " "))}")
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

  defp vision_schema_batch(name, opts) do
    runs = opts[:runs] || 2
    concurrency = opts[:concurrency] || 4

    Mix.shell().info(
      "testing production vision schema on fixed #{name} boundaries, " <>
        "#{runs} run(s), concurrency #{concurrency}"
    )

    {:ok, report} =
      Nila.Eval.VisionSchemaBatch.run(name,
        runs: runs,
        max_concurrency: concurrency
      )

    Enum.each(report["results"], fn result ->
      if result["status"] == "ok" do
        Mix.shell().info(
          "  run #{result["run"]}/#{runs}: #{result["invoice_count"]} invoices, " <>
            "#{result["line_count"]} lines, #{result["flagged_count"]} flagged"
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
end
