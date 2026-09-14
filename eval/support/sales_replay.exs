defmodule Nila.Eval.SalesReplay do
  @moduledoc """
  Replays saved extraction responses through the current sales accounting code.

  `replay/5` accepts the saved response, field order, amount contract, seller
  GSTIN, and source pages explicitly. It does not invoke a model or judge the
  response against ground truth.

  `run/2` preserves the historical Simple Systems June benchmark's manifest,
  method-to-contract mapping, and seller GSTIN. It writes accounting beside
  the inputs, or creates a separate output directory when one is supplied.
  """

  alias Nila.Gst.Extraction.InvoiceRepairs
  alias Nila.Gst.Extraction.Sales.Normalizer

  def run(root, output_root \\ nil) do
    if output_root, do: File.mkdir_p!(output_root)
    output_root = output_root || root
    old = read_json(root, "old-fields.json")
    new = read_json(root, "new-fields.json")
    truth = read_json(root, "expected.json")

    for entry <- read_json(root, "manifest.json")["schedule"] do
      prefix = String.pad_leading(to_string(entry["sequence"]), 2, "0") <> "-" <> entry["arm"]
      path = Path.join(root, prefix <> "-data.json")

      if File.exists?(path) do
        data = File.read!(path) |> Jason.decode!()
        is_new = entry["method"] in ["poppler", "plain", "markdown"]
        fields = if is_new, do: new, else: old
        contract = if is_new, do: :two_amount, else: :legacy

        accounting =
          replay(
            data,
            fields,
            contract,
            "33AEHFS3648M1ZL",
            Enum.to_list(1..truth[entry["case"]]["page_count"])
          )

        File.write!(
          Path.join(output_root, prefix <> "-accounting.json"),
          Jason.encode!(accounting, pretty: true)
        )
      end
    end

    IO.puts("Replayed available saved responses")
  end

  @doc """
  Replays one decoded response using `:legacy` or `:two_amount` row amounts.

  Rows may be positional arrays (decoded using `fields`) or named maps. The
  two-amount contract maps `amount_before_gst` and `amount_including_gst` to
  printed taxable value and printed line total before sales repairs run.
  """
  def replay(data, fields, contract, client_gstin, source_pages)
      when contract in [:legacy, :two_amount] do
    decoded =
      Map.update!(data, "line_items", fn rows ->
        Enum.map(rows, fn row ->
          if is_list(row), do: Map.new(Enum.zip(fields, row)), else: row
        end)
      end)

    adapted =
      if contract == :two_amount do
        Map.update!(decoded, "line_items", fn rows ->
          Enum.map(rows, fn row ->
            row
            |> Map.put("printed_line_amount", nil)
            |> Map.put("printed_taxable_value", row["amount_before_gst"])
            |> Map.put("printed_line_total", row["amount_including_gst"])
            |> Map.put("line_amount_tax_inclusion", "unknown")
          end)
        end)
      else
        decoded
      end

    {prepared, repairs} = InvoiceRepairs.prepare(adapted, :sales, client_gstin)

    normalized =
      Normalizer.normalize(%{
        "data" => prepared,
        "page" => 1,
        "source_pages" => source_pages
      })

    %{raw_named: decoded, prepared: prepared, normalized: normalized, repairs: repairs}
  end

  defp read_json(root, name), do: root |> Path.join(name) |> File.read!() |> Jason.decode!()
end
