defmodule Mix.Tasks.Nila.EvalSalesPdf do
  @shortdoc "Evaluates local sales PDFs through text/vision, review and draft workings"
  @moduledoc """
      mix nila.eval_sales_pdf <file-or-directory> --gstin GSTIN --name NAME --period YYYY-MM [--input text|vision]

  Text input is explicit for known digital PDFs. Empty pages retain vision.
  Writes a fresh attempt under tmp/eval/sales-pdf, including machine draft JSON,
  the existing workings workbook, issues, native text, page images and raw responses.
  Does not import invoices, record human approvals or publish a return.
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [gstin: :string, name: :string, period: :string, input: :string]
      )

    if invalid != [] or length(positional) != 1, do: Mix.raise(@moduledoc)

    for key <- [:gstin, :name, :period],
        do: if(!opts[key] or String.trim(opts[key]) == "", do: Mix.raise("--#{key} is required"))

    unless Regex.match?(~r/^\d{4}-(0[1-9]|1[0-2])$/, opts[:period]),
      do: Mix.raise("--period must be YYYY-MM")

    input =
      case opts[:input] || "text" do
        "text" -> :text
        "vision" -> :vision
        _ -> Mix.raise("--input must be text or vision")
      end

    [path] = positional

    paths =
      if File.dir?(path), do: Path.wildcard(Path.join(path, "*.pdf")) |> Enum.sort(), else: [path]

    if paths == [] or Enum.any?(paths, &(not File.regular?(&1))),
      do: Mix.raise("No readable PDF sources")

    Mix.Task.run("app.config")
    # This is a file-based eval. Do not start Repo, Oban or the web endpoint.
    for app <- [:req, :jsv, :xlsx_writer] do
      {:ok, _apps} = Application.ensure_all_started(app)
    end

    {:ok, _supervisor} =
      Supervisor.start_link([Nila.Gst.Extraction.OpenAICompatibleChatFinch],
        strategy: :one_for_one
      )

    {:ok, summary} =
      Nila.Eval.SalesPdf.run(paths, %{gstin: opts[:gstin], name: opts[:name]}, opts[:period],
        input: input,
        on_file: &Mix.shell().info(Jason.encode!(&1))
      )

    Mix.shell().info(Jason.encode!(summary, pretty: true))
  end
end
