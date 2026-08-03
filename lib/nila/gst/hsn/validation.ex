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

  def sales_issues(invoices) do
    Enum.flat_map(invoices, fn invoice ->
      invoice["line_items"]
      |> List.wrap()
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, index} -> sales_line_issues(invoice, line, index) end)
    end)
  end

  def summary_issues(invoices, historical_observations \\ []) do
    multiple_rate_issues(invoices) ++
      new_code_issues(invoices, historical_observations) ++ inferred_code_issues(invoices)
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
      "source_id" => invoice["id"],
      "code" => issue_code(status),
      "level" => Issues.level_for(issue_code(status)),
      "message" => reason(line, index, status),
      "fields" => ["line_items[#{index - 1}].hsn_sac"],
      "hsn_code" => line["hsn_sac"]
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
        "target" => "hsn_new_code|#{code}"
      }
    end)
  end

  defp inferred_code_issues(invoices) do
    invoices
    |> Enum.flat_map(fn invoice ->
      invoice["line_items"]
      |> List.wrap()
      |> Enum.filter(&(&1["hsn_inferred"] == true))
      |> Enum.map(fn line ->
        %{
          "invoice" => invoice["invoice_number"],
          "source_id" => invoice["id"],
          "code" => "hsn_inferred_code",
          "level" => Issues.level_for("hsn_inferred_code"),
          "message" =>
            "HSN/SAC #{line["hsn_sac"]} was inferred rather than read from the source document",
          "fields" => ["line_items"],
          "hsn_code" => line["hsn_sac"]
        }
      end)
    end)
  end

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
