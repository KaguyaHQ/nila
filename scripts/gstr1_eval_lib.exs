defmodule Gstr1Eval do
  @moduledoc """
  Script-only IO/CLI shim around the `Nila.Gst.Gstr1` engine.

  The pure derivation, validation, and correction logic lives in
  `lib/nila/gst/gstr1.ex` (tested). This module only holds what a CLI eval run
  needs and the product must not: arg parsing, fixture-directory conventions,
  JSON file IO, page-artifact loading, console report printing, and the
  field-level diff/scoring of a derived return against a filed return (the
  product never scores itself). The derivation/validation/correction logic
  delegates to `Nila.Gst.Gstr1`.
  """
  alias Nila.Gst.Gstr1

  @diff_tolerance 0.01
  @ignored_invoice_fields ~w(chksum flag updby cflag)

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

  @doc """
  Field-level diff of a derived GSTR-1 against a filed return, scored as a
  match percentage. Eval-only — the product never scores itself.
  """
  def diff(derived, filed) do
    invoice_diffs = diff_invoices(derived, filed)
    hsn_diffs = diff_hsn(derived, filed)
    doc_diffs = diff_doc(derived, filed)
    rows = invoice_diffs ++ hsn_diffs ++ doc_diffs
    matches = Enum.count(rows, & &1["match"])
    total = length(rows)
    score = if total == 0, do: 0.0, else: matches * 100 / total

    %{
      "score" => Float.round(score, 2),
      "matches" => matches,
      "total" => total,
      "mismatches" => Enum.reject(rows, & &1["match"]),
      "rows" => rows
    }
  end

  defp diff_invoices(derived, filed) do
    derived_rows = invoice_rows(derived)
    filed_rows = invoice_rows(filed)
    keys = (Map.keys(derived_rows) ++ Map.keys(filed_rows)) |> Enum.uniq() |> Enum.sort()
    invoice_fields = ~w(ctin inum idt val pos rchrg inv_typ)
    item_fields = ~w(rt txval camt samt iamt csamt)

    Enum.flat_map(keys, fn key ->
      derived = derived_rows[key] || %{}
      filed = filed_rows[key] || %{}

      invoice_checks =
        Enum.map(invoice_fields, fn field ->
          diff_row("invoice", key, field, derived[field], filed[field])
        end)

      item_checks =
        Enum.map(item_fields, fn field ->
          diff_row(
            "invoice_item",
            key,
            field,
            get_in(derived, ["itm_det", field]),
            get_in(filed, ["itm_det", field])
          )
        end)

      invoice_checks ++ item_checks
    end)
  end

  defp invoice_rows(gstr1) do
    for ctin_block <- gstr1["b2b"] || [],
        inv <- ctin_block["inv"] || [],
        item <- inv["itms"] || [],
        reduce: %{} do
      acc ->
        cleaned_inv = Map.drop(inv, @ignored_invoice_fields)
        key = "#{ctin_block["ctin"]}|#{inv["inum"]}|#{get_in(item, ["itm_det", "rt"])}"

        Map.put(
          acc,
          key,
          cleaned_inv
          |> Map.put("ctin", ctin_block["ctin"])
          |> Map.put("itm_det", item["itm_det"] || %{})
        )
    end
  end

  defp diff_hsn(derived, filed) do
    derived_rows = hsn_rows(derived)
    filed_rows = hsn_rows(filed)
    keys = (Map.keys(derived_rows) ++ Map.keys(filed_rows)) |> Enum.uniq() |> Enum.sort()

    Enum.flat_map(keys, fn key ->
      Enum.map(~w(hsn_sc rt txval camt samt iamt), fn field ->
        diff_row(
          "hsn",
          key,
          field,
          get_in(derived_rows, [key, field]),
          get_in(filed_rows, [key, field])
        )
      end)
    end)
  end

  defp hsn_rows(gstr1) do
    for row <- get_in(gstr1, ["hsn", "hsn_b2b"]) || [], reduce: %{} do
      acc -> Map.put(acc, "#{row["hsn_sc"]}|#{row["rt"]}", row)
    end
  end

  defp diff_doc(derived, filed) do
    derived_doc =
      get_in(derived, ["doc_issue", "doc_det", Access.at(0), "docs", Access.at(0)]) || %{}

    filed_doc = get_in(filed, ["doc_issue", "doc_det", Access.at(0), "docs", Access.at(0)]) || %{}

    Enum.map(~w(from to totnum net_issue cancel), fn field ->
      diff_row("doc_issue", "doc_issue", field, derived_doc[field], filed_doc[field])
    end)
  end

  defp diff_row(scope, key, field, derived, filed) do
    %{
      "scope" => scope,
      "key" => key,
      "field" => field,
      "derived" => derived,
      "filed" => filed,
      "match" => equivalent?(field, derived, filed)
    }
  end

  # Auditor entry convention varies between whole-rupee rounding and paise for invoice val.
  defp equivalent?("val", a, b) when is_number(a) or is_number(b) do
    close?(num(a), num(b), 1.0)
  end

  defp equivalent?(_field, a, b) when is_number(a) or is_number(b) do
    close?(num(a), num(b), @diff_tolerance)
  end

  defp equivalent?(_field, a, b), do: normalize_blank(a) == normalize_blank(b)

  defp close?(a, b, tolerance), do: abs(num(a) - num(b)) <= tolerance + 0.000001

  defp normalize_blank(nil), do: nil
  defp normalize_blank(value) when is_binary(value), do: String.trim(value)
  defp normalize_blank(value), do: value

  defp num(nil), do: 0
  defp num(value) when is_integer(value), do: value / 1
  defp num(value) when is_float(value), do: value

  defp num(value) when is_binary(value) do
    case value |> String.replace(",", "") |> String.replace(~r/[^0-9.\-]/, "") |> Float.parse() do
      {number, _} -> number
      :error -> 0
    end
  end

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
