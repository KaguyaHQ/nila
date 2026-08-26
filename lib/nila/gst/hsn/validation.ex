defmodule Nila.Gst.Hsn.Validation do
  @moduledoc "Pure HSN/SAC annotation and invoice validation against one master release."

  alias Nila.Gst.Hsn.Directory
  alias Nila.Gst.Issues
  alias Nila.Gst.RateHistory

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

  # A code Nila inferred and has never seen before is one fact, and it reached
  # the reviewer twice: `hsn_inferred_code` at `required` on the line, and
  # `hsn_new_code` at `advisory` on the code, the latter carrying `hsn_inferred`
  # to say the same thing again in a field. The required row is the one that
  # gates, so it absorbs the novelty and the advisory stands down. A new code
  # somebody actually read off a bill still raises its own advisory — nothing is
  # asserted to be wrong with it, and that is exactly what advisory is for.
  def summary_issues(invoices, historical_observations \\ []) do
    {inferred_novelty, novelty} =
      invoices
      |> new_code_issues(historical_observations)
      |> Enum.split_with(& &1["hsn_inferred"])

    inferred_codes = MapSet.new(inferred_novelty, & &1["hsn_code"])

    multiple_rate_issues(invoices) ++
      novelty ++ inferred_code_issues(invoices, inferred_codes)
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

  defp multiple_rate_issues(invoices) do
    invoices
    |> observations()
    |> Enum.group_by(& &1.code)
    |> Enum.flat_map(fn {code, observations} ->
      rates = observations |> Enum.map(& &1.rate) |> Enum.uniq() |> Enum.sort()

      if length(rates) > 1 do
        source_ids = observations |> Enum.map(& &1.source_id) |> Enum.uniq()
        invoice_numbers = observations |> Enum.map(& &1.invoice) |> Enum.uniq()

        [
          %{
            "invoice" => nil,
            "source_ids" => source_ids,
            "code" => "hsn_multiple_rates",
            "level" => Issues.level_for("hsn_multiple_rates"),
            "message" =>
              "HSN/SAC #{code} appears at #{Enum.map_join(rates, " and ", &rate_label/1)} across invoices #{Enum.join(invoice_numbers, ", ")}",
            "fields" => ["line_items"],
            "hsn_code" => code,
            "hsn_rates" => rates,
            "target" => "hsn_multiple_rates|#{code}"
          }
        ]
      else
        []
      end
    end)
  end

  defp new_code_issues(_invoices, []), do: []

  defp new_code_issues(invoices, historical_observations) do
    historical_codes = MapSet.new(historical_observations, & &1.code)

    invoices
    |> observations()
    |> Enum.reject(&MapSet.member?(historical_codes, &1.code))
    |> Enum.group_by(& &1.code)
    |> Enum.map(fn {code, observations} ->
      %{
        "invoice" => nil,
        "source_ids" => observations |> Enum.map(& &1.source_id) |> Enum.uniq(),
        "code" => "hsn_new_code",
        "level" => Issues.level_for("hsn_new_code"),
        "message" => "HSN/SAC #{code} has not appeared in this client's prior 12 sales months",
        "fields" => ["line_items"],
        "hsn_code" => code,
        "hsn_rates" => observations |> Enum.map(& &1.rate) |> Enum.uniq() |> Enum.sort(),
        # What a reviewer would ask for if he decided to look: the portal's own
        # description, how much rides on the code, which bills carry it, and
        # whether anyone actually read it off one.
        "hsn_description" => observations |> Enum.find_value(& &1.description),
        "hsn_taxable" => observations |> Enum.map(& &1.taxable) |> Enum.sum(),
        "hsn_invoices" => observations |> Enum.map(& &1.invoice) |> Enum.uniq() |> Enum.sort(),
        "hsn_inferred" => Enum.any?(observations, & &1.inferred),
        "target" => "hsn_new_code|#{code}"
      }
    end)
  end

  # One issue per invoice, for the same reason as `sales_issues/1`: every
  # inferred line on one bill posts the same `source_id:hsn_inferred_code`
  # target, so a row per line was a count nobody could clear line by line.
  defp inferred_code_issues(invoices, novel_codes) do
    Enum.flat_map(invoices, fn invoice ->
      invoice["line_items"]
      |> List.wrap()
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _index} -> line["hsn_inferred"] == true end)
      |> case do
        [] -> []
        lines -> [inferred_code_issue(invoice, lines, novel_codes)]
      end
    end)
  end

  defp inferred_code_issue(invoice, lines, novel_codes) do
    codes = lines |> Enum.map(fn {line, _index} -> line["hsn_sac"] end) |> Enum.uniq()
    novel = Enum.filter(codes, &MapSet.member?(novel_codes, &1))

    %{
      "invoice" => invoice["invoice_number"],
      "source_id" => invoice["id"],
      "code" => "hsn_inferred_code",
      "level" => Issues.level_for("hsn_inferred_code"),
      "message" => inferred_message(lines, codes) <> novelty_clause(novel),
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

  defp novelty_clause([]), do: ""

  defp novelty_clause([code]),
    do: ". #{code} has not appeared in this client's prior 12 sales months"

  defp novelty_clause(codes),
    do: ". #{Enum.join(codes, ", ")} have not appeared in this client's prior 12 sales months"

  defp observations(invoices) do
    Enum.flat_map(invoices, fn invoice ->
      invoice["line_items"]
      |> List.wrap()
      |> Enum.flat_map(fn line ->
        with code when is_binary(code) and code != "" <- line["hsn_sac"],
             {:ok, rate} <- RateHistory.line_rate(line) do
          [
            %{
              code: code,
              rate: rate,
              description: line["hsn_description"],
              taxable: line["taxable_value"] || 0,
              inferred: line["hsn_inferred"] == true,
              source_id: invoice["id"],
              invoice: invoice["invoice_number"]
            }
          ]
        else
          _ -> []
        end
      end)
    end)
  end

  defp rate_label(rate) when rate == trunc(rate), do: "#{trunc(rate)}%"
  defp rate_label(rate), do: "#{rate}%"

  defp issue_code("missing"), do: "missing_hsn_sac"
  defp issue_code("incomplete"), do: "incomplete_hsn_sac"
  defp issue_code("invalid"), do: "invalid_hsn_sac"

  defp description(line), do: line["description"] || "unnamed item"

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
