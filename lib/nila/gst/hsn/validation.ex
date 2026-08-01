defmodule Nila.Gst.Hsn.Validation do
  @moduledoc "Pure HSN/SAC annotation and invoice validation against one master release."

  alias Nila.Gst.Hsn.Directory

  def annotate_invoices(invoices, directory) do
    Enum.map(invoices, fn invoice ->
      Map.update(invoice, "line_items", [], fn lines ->
        Enum.map(lines, &annotate_line(&1, directory))
      end)
    end)
  end

  def sales_issues(invoices) do
    Enum.flat_map(invoices, fn invoice ->
      invoice["line_items"]
      |> List.wrap()
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, index} -> sales_line_issues(invoice, line, index) end)
    end)
  end

  def purchase_flags(invoice) do
    invoice["line_items"]
    |> List.wrap()
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, index} -> purchase_line_flags(invoice, line, index) end)
  end

  defp annotate_line(line, directory) do
    validation = Directory.validate(line["hsn_sac"], directory)

    line
    |> Map.put("hsn_validation", stringify(validation))
    |> maybe_put("hsn_description", validation[:description])
    |> maybe_put("hsn_kind", validation[:kind])
  end

  defp sales_line_issues(invoice, line, index) do
    case get_in(line, ["hsn_validation", "status"]) do
      "valid" ->
        []

      status when status in ~w(missing incomplete invalid) ->
        [sales_issue(invoice, line, index, status)]

      _not_checked ->
        []
    end
  end

  defp sales_issue(invoice, line, index, status) do
    %{
      "invoice" => invoice["invoice_number"],
      "code" => issue_code(status),
      "message" => reason(line, index, status),
      "fields" => ["line_items[#{index - 1}].hsn_sac"]
    }
  end

  defp purchase_line_flags(invoice, line, index) do
    case get_in(line, ["hsn_validation", "status"]) do
      "valid" ->
        []

      status when status in ~w(missing incomplete invalid) ->
        [purchase_flag(invoice, line, index, status)]

      _not_checked ->
        []
    end
  end

  defp purchase_flag(invoice, line, index, status) do
    %{
      "invoice_id" => invoice["id"],
      "code" => issue_code(status),
      "severity" => "review",
      "reason" => reason(line, index, status),
      "section" => nil,
      "fields" => ["line_items"],
      "confidence" => 1.0
    }
  end

  defp reason(line, index, "missing") do
    "Line #{index} \"#{description(line)}\" has no HSN/SAC code. Confirm it before filing."
  end

  defp reason(line, index, "incomplete") do
    "Line #{index} \"#{description(line)}\" carries #{line["hsn_sac"]}, which is only a " <>
      "prefix of codes in the active portal directory and is not itself an exact entry. " <>
      "Select the exact HSN/SAC printed or confirmed by the reviewer."
  end

  defp reason(line, index, "invalid") do
    "Line #{index} \"#{description(line)}\" carries #{line["hsn_sac"]}, which does not " <>
      "exist in the active portal HSN/SAC directory."
  end

  defp issue_code("missing"), do: "missing_hsn_sac"
  defp issue_code("incomplete"), do: "incomplete_hsn_sac"
  defp issue_code("invalid"), do: "invalid_hsn_sac"

  defp description(line), do: line["description"] || "unnamed item"

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
