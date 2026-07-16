defmodule Gstr1Eval do
  @moduledoc """
  Script-only IO/CLI shim around the `Nila.Gst.Gstr1` engine.

  The pure derivation, validation, correction, and diff logic lives in
  `lib/nila/gst/gstr1.ex` (tested). This module only holds what a CLI eval run
  needs and the product must not: arg parsing, fixture-directory conventions,
  JSON file IO, page-artifact loading, and console report printing. Everything
  substantive delegates to `Nila.Gst.Gstr1`.
  """
  alias Nila.Gst.Gstr1

  def default_fixture_dir do
    Path.expand("../test/fixtures/gstr1/breeze/2026-05", __DIR__)
  end

  def default_out_dir do
    default_fixture_dir() |> default_out_dir_for_fixture()
  end

  def parse_args(args) do
    {opts, _argv, _invalid} =
      OptionParser.parse(args,
        strict: [
          fixture_dir: :string,
          out_dir: :string,
          pdf: :string,
          filed: :string,
          pages: :string,
          corrections: :string
        ]
      )

    fixture_dir = Path.expand(opts[:fixture_dir] || default_fixture_dir())
    out_dir = Path.expand(opts[:out_dir] || default_out_dir_for_fixture(fixture_dir))

    %{
      fixture_dir: fixture_dir,
      out_dir: out_dir,
      pdf_path: Path.expand(opts[:pdf] || single_fixture_file!(fixture_dir, "*.pdf", "PDF")),
      filed_path:
        Path.expand(
          opts[:filed] || single_fixture_file!(fixture_dir, "returns_*.json", "filed return JSON")
        ),
      pages_dir: Path.expand(opts[:pages] || Path.join(out_dir, "pages")),
      corrections_path:
        (opts[:corrections] && Path.expand(opts[:corrections])) ||
          optional_fixture_file(fixture_dir, "corrections.json")
    }
  end

  defp default_out_dir_for_fixture(fixture_dir) do
    period = Path.basename(fixture_dir)
    seller = fixture_dir |> Path.dirname() |> Path.basename()
    Path.expand("../tmp/eval/#{period}-#{seller}", __DIR__)
  end

  defp single_fixture_file!(fixture_dir, pattern, label) do
    matches = fixture_dir |> Path.join(pattern) |> Path.wildcard() |> Enum.sort()

    case matches do
      [path] ->
        path

      [] ->
        Mix.raise("no #{label} found in #{fixture_dir}; pass it explicitly")

      paths ->
        Mix.raise(
          "multiple #{label} files found in #{fixture_dir}; pass one explicitly: #{Enum.join(paths, ", ")}"
        )
    end
  end

  defp optional_fixture_file(fixture_dir, filename) do
    path = Path.join(fixture_dir, filename)
    if File.exists?(path), do: path
  end

  def read_json!(path), do: path |> File.read!() |> Jason.decode!()

  def write_json!(path, value) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, Jason.encode!(value, pretty: true))
  end

  def load_invoices!(pages_dir) do
    pages_dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.sort_by(&page_sort_key/1)
    |> Enum.map(&read_json!/1)
    |> Enum.map(&Gstr1.normalize_invoice/1)
  end

  # Delegations to the tested engine, kept so the runner reads the same.
  defdelegate normalize_invoice(raw), to: Gstr1
  defdelegate validation_issues(invoices), to: Gstr1
  defdelegate flagged_fields(invoices, issues), to: Gstr1
  defdelegate derive_gstr1(invoices, filed), to: Gstr1, as: :derive
  defdelegate diff(derived, filed), to: Gstr1

  @doc """
  Applies corrections from a patch file path (script convenience). Reads and
  decodes the file, then delegates to `Nila.Gst.Gstr1.apply_corrections/3`.
  """
  def apply_corrections(invoices, nil, flagged), do: Gstr1.apply_corrections(invoices, nil, flagged)

  def apply_corrections(invoices, path, flagged) when is_binary(path) do
    decoded = read_json!(path)
    corrections = decoded["corrections"] || decoded
    Gstr1.apply_corrections(invoices, corrections, flagged)
  end

  def print_report(report) do
    IO.puts(
      "raw score: #{report["raw"]["score"]}% (#{report["raw"]["matches"]}/#{report["raw"]["total"]})"
    )

    if report["final"] do
      IO.puts(
        "final score: #{report["final"]["score"]}% (#{report["final"]["matches"]}/#{report["final"]["total"]})"
      )

      IO.puts("flagged corrections: #{length(report["flagged_corrections"])}")
      IO.puts("silent errors: #{length(report["silent_errors"])}")
    end

    IO.puts("issues: #{length(report["issues"])}")

    report["issues"]
    |> Enum.each(fn issue ->
      where = issue["invoice"] || "bundle"
      level = if issue["level"], do: " [#{issue["level"]}]", else: ""
      IO.puts("- #{where}: #{issue["code"]}#{level} #{issue["message"]}")
    end)

    case report["raw"]["mismatches"] do
      [] ->
        IO.puts("mismatches: 0")

      mismatches ->
        IO.puts("mismatches: #{length(mismatches)}")

        mismatches
        |> Enum.take(40)
        |> Enum.each(fn row ->
          IO.puts(
            "- #{row["scope"]} #{row["key"]} #{row["field"]}: derived=#{inspect(row["derived"])} filed=#{inspect(row["filed"])}"
          )
        end)
    end
  end

  defp page_sort_key(path) do
    case Regex.run(~r/(\d+)/, Path.basename(path)) do
      [_, number] -> String.to_integer(number)
      _ -> 999_999
    end
  end
end
