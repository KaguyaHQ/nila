defmodule Nila.Gst.Hsn.Validation do
  @moduledoc "Pure HSN/SAC annotation and invoice validation against one master release."

  alias Nila.Gst.Hsn.Directory
  alias Nila.Gst.Issues

  def annotate_invoices(invoices, directory) do
    Enum.map(invoices, fn invoice ->
      Map.update(invoice, "line_items", [], fn lines ->
        Enum.map(lines, &annotate_line(&1, directory))
      end)
    end)
  end

  # One issue per invoice and status, not per line. The resolution target is
  # `source_id:code` (`Sales.Workings.issue_key/1`), so five lines carrying the
  # same unknown code posted five rows against one target — answering any of
  # them resolved all five. The lines are what a reviewer corrects, so they move
  # into the message and into `lines` rather than out of the account.
  def sales_issues(invoices) do
    Enum.flat_map(invoices, fn invoice ->
      findings =
        invoice["line_items"]
        |> List.wrap()
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {line, index} -> sales_line_findings(line, index) end)

      findings
      |> Enum.map(& &1.status)
      |> Enum.uniq()
      |> Enum.map(fn status ->
        sales_issue(invoice, status, Enum.filter(findings, &(&1.status == status)))
      end)
    end)
  end

  # Inferred HSN/SAC codes remain an explicit confirmation because the source
  # document did not supply that fact directly. No sales rate or historical
  # novelty judgment belongs in this summary.
  def summary_issues(invoices) do
    inferred_code_issues(invoices)
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

  defp sales_line_findings(line, index) do
    case get_in(line, ["hsn_validation", "status"]) do
      status when status in ~w(missing incomplete invalid) ->
        [%{status: status, line: index, code: line["hsn_sac"], description: description(line)}]

      _valid_or_not_checked ->
        if blank?(line["hsn_sac"]) do
          [%{status: "missing", line: index, code: nil, description: description(line)}]
        else
          []
        end
    end
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp sales_issue(invoice, status, findings) do
    code = issue_code(status)
    codes = findings |> Enum.map(& &1.code) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    %{
      "invoice" => invoice["invoice_number"],
      "source_id" => invoice["id"],
      "code" => code,
      "level" => Issues.level_for(code),
      "message" => sales_reason(findings, status),
      "fields" => Enum.map(findings, &"line_items[#{&1.line - 1}].hsn_sac"),
      "lines" => Enum.map(findings, & &1.line),
      # Every code the merged issue speaks for, not only the first one found.
      # The reviewer-side gate expands the workings rows for the code it is
      # handed and unlocks the answer once they are all open, so an invoice
      # carrying two bad codes would unlock on the first — the second code's
      # rows never rendered, and before the collapse that took two reviews.
      # `hsn_code` stays a single code because the expand event and the novelty
      # table each take one; the list is what a gate has to read.
      "hsn_code" => List.first(codes),
      "hsn_codes" => codes
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
      "reason" => reason(line, index, status),
      "section" => nil,
      "fields" => ["line_items"],
      "confidence" => 1.0
    }
  end

  # One line reads as it always did. Several read as one sentence naming every
  # line, rather than the same sentence repeated with a different number in it —
  # the reviewer is looking at one invoice and one target, and the list of lines
  # is the correction he has to make.
  defp sales_reason([%{line: index, description: description}], "missing") do
    "Line #{index} \"#{description}\" has no HSN/SAC code. Confirm it before filing."
  end

  defp sales_reason([%{line: index, description: description, code: code}], "incomplete") do
    "Line #{index} \"#{description}\" carries #{code}, which is only a " <>
      "prefix of codes in the active portal directory and is not itself an exact entry. " <>
      "Select the exact HSN/SAC printed or confirmed by the reviewer."
  end

  defp sales_reason([%{line: index, description: description, code: code}], "invalid") do
    "Line #{index} \"#{description}\" carries #{code}, which does not " <>
      "exist in the active portal HSN/SAC directory."
  end

  defp sales_reason(findings, "missing") do
    "#{lines_phrase(findings)} have no HSN/SAC code: #{descriptions_phrase(findings)}. " <>
      "Confirm them before filing."
  end

  defp sales_reason(findings, "incomplete") do
    "#{lines_phrase(findings)} carry codes that are only prefixes of entries in the active " <>
      "portal directory, not exact entries: #{codes_phrase(findings)}. Select the exact " <>
      "HSN/SAC printed or confirmed by the reviewer."
  end

  defp sales_reason(findings, "invalid") do
    "#{lines_phrase(findings)} carry codes that do not exist in the active portal HSN/SAC " <>
      "directory: #{codes_phrase(findings)}."
  end

  defp lines_phrase(findings), do: "Lines " <> Enum.map_join(findings, ", ", &"#{&1.line}")

  defp descriptions_phrase(findings) do
    findings |> Enum.map(&"\"#{&1.description}\"") |> Enum.uniq() |> Enum.join(", ")
  end

  defp codes_phrase(findings) do
    findings |> Enum.map(&to_string(&1.code)) |> Enum.uniq() |> Enum.join(", ")
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

  # One issue per invoice, for the same reason as `sales_issues/1`: every
  # inferred line on one bill posts the same `source_id:hsn_inferred_code`
  # target, so a row per line was a count nobody could clear line by line.
  defp inferred_code_issues(invoices) do
    Enum.flat_map(invoices, fn invoice ->
      invoice["line_items"]
      |> List.wrap()
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _index} -> line["hsn_inferred"] == true end)
      |> case do
        [] -> []
        lines -> [inferred_code_issue(invoice, lines)]
      end
    end)
  end

  defp inferred_code_issue(invoice, lines) do
    codes = lines |> Enum.map(fn {line, _index} -> line["hsn_sac"] end) |> Enum.uniq()

    %{
      "invoice" => invoice["invoice_number"],
      "source_id" => invoice["id"],
      "code" => "hsn_inferred_code",
      "level" => Issues.level_for("hsn_inferred_code"),
      "message" => inferred_message(lines, codes),
      "fields" => ["line_items"],
      "lines" => Enum.map(lines, fn {_line, index} -> index end),
      "hsn_code" => List.first(codes),
      "hsn_codes" => codes
    }
  end

  defp inferred_message([{line, _index}], _codes) do
    "HSN/SAC #{line["hsn_sac"]} was inferred rather than read from the source document"
  end

  defp inferred_message(lines, codes) do
    "HSN/SAC #{Enum.join(codes, ", ")} on lines " <>
      Enum.map_join(lines, ", ", fn {_line, index} -> "#{index}" end) <>
      " were inferred rather than read from the source document"
  end

  defp issue_code("missing"), do: "missing_hsn_sac"
  defp issue_code("incomplete"), do: "incomplete_hsn_sac"
  defp issue_code("invalid"), do: "invalid_hsn_sac"

  defp description(line), do: line["description"] || "unnamed item"

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
