defmodule Nila.Gst.Rates.Validation do
  @moduledoc "Matches HSN goods to effective-dated candidates; SAC and description-only Any Chapter rules remain unchecked."

  alias Nila.Gst.Issues
  alias Nila.Gst.RateHistory

  @rate_tolerance 0.05

  @correction_advice "Confirm whether the HSN or rate needs correction; " <>
                       "exemptions and description-dependent conditions are not " <>
                       "automatically resolved."

  def annotate_invoices(invoices, directory) do
    Enum.map(invoices, fn invoice ->
      Map.update(invoice, "line_items", [], fn lines ->
        Enum.map(lines, &annotate_line(&1, invoice["invoice_date"], directory))
      end)
    end)
  end

  # One issue per invoice and status, not per line, for the reason spelled out
  # in `Hsn.Validation.sales_issues/1`: the resolution target is
  # `source_id:code` (`Sales.Workings.issue_key/1`), so three flagged lines on
  # one bill posted three rows a reviewer could only answer once.
  #
  # The merge belongs here rather than to the generic `collapse_by_target/1`,
  # which keeps the first row's map wholesale and unions only message, fields
  # and lines. Statutory candidates are per code, and the codes differ across
  # the lines being merged — so that merge left the card offering line 1's
  # candidate rates beside a message naming lines 1, 3 and 4, which is a
  # citation against the wrong entry. Here the candidates and the codes are
  # unioned with the lines that produced them, and each line keeps its own
  # sentence naming its own code, rate and notification entry.
  def sales_issues(invoices) do
    Enum.flat_map(invoices, fn invoice ->
      findings =
        invoice["line_items"]
        |> List.wrap()
        |> Enum.with_index(1)
        |> Enum.flat_map(&line_finding/1)

      findings
      |> Enum.map(& &1.status)
      |> Enum.uniq()
      |> Enum.map(fn status ->
        sales_issue(invoice, status, Enum.filter(findings, &(&1.status == status)))
      end)
    end)
  end

  def purchase_flags(invoice) do
    invoice["line_items"]
    |> List.wrap()
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, index} ->
      case line["rate_validation"] do
        %{"status" => status} = validation when status in ~w(incompatible review) ->
          [
            %{
              "invoice_id" => invoice["id"],
              "code" => issue_code(status),
              "severity" => "review",
              "reason" => message(line, index, validation),
              "section" => nil,
              "fields" => ["line_items"],
              "confidence" => if(status == "incompatible", do: 0.95, else: 0.7)
            }
          ]

        _ ->
          []
      end
    end)
  end

  defp line_finding({line, index}) do
    case line["rate_validation"] do
      %{"status" => status} = validation when status in ~w(incompatible review) ->
        [
          %{
            status: status,
            line: index,
            code: line["hsn_sac"],
            rates: List.wrap(validation["candidate_rates"]),
            reason: line_reason(line, index, validation),
            fields: [
              "line_items[#{index - 1}].hsn_sac",
              "line_items[#{index - 1}].cgst_rate",
              "line_items[#{index - 1}].sgst_rate",
              "line_items[#{index - 1}].igst_rate"
            ]
          }
        ]

      _ ->
        []
    end
  end

  defp sales_issue(invoice, status, findings) do
    code = issue_code(status)
    codes = findings |> Enum.map(& &1.code) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    %{
      "invoice" => invoice["invoice_number"],
      "source_id" => invoice["id"],
      "code" => code,
      "level" => Issues.level_for(code),
      "message" => Enum.map_join(findings, " ", & &1.reason) <> " " <> @correction_advice,
      # `hsn_code` is one code because the callers that take a code take one;
      # `hsn_codes` is what the merged issue actually covers, and any gate that
      # asks "has the reviewer seen this" has to read the list.
      "hsn_code" => List.first(codes),
      "hsn_codes" => codes,
      "hsn_rates" => findings |> Enum.flat_map(& &1.rates) |> Enum.uniq() |> Enum.sort(),
      "lines" => Enum.map(findings, & &1.line),
      "fields" => findings |> Enum.flat_map(& &1.fields) |> Enum.uniq()
    }
  end

  defp annotate_line(%{"hsn_kind" => "hsn"} = line, invoice_date, directory) do
    validation = validate(line, invoice_date, directory)
    Map.put(line, "rate_validation", stringify(validation))
  end

  defp annotate_line(line, _invoice_date, _directory), do: line

  defp validate(line, invoice_date, directory) do
    release = directory.release

    with {:ok, date} <- invoice_date(invoice_date),
         true <- Date.compare(date, release.effective_from) != :lt,
         {:ok, printed_rate, rate_source} <- RateHistory.line_rate_with_source(line),
         [_ | _] = rules <- matching_rules(line["hsn_sac"], directory.rules) do
      candidates = candidates(rules, release)
      rates = Enum.map(candidates, & &1.rate)

      status =
        cond do
          Enum.any?(rates, &(abs(&1 - printed_rate) <= @rate_tolerance)) ->
            "compatible"

          rate_source == :printed and Enum.all?(candidates, &(&1.confidence == "automatic")) ->
            "incompatible"

          true ->
            "review"
        end

      %{
        status: status,
        printed_rate: printed_rate,
        candidate_rates: rates |> Enum.uniq() |> Enum.sort(),
        candidates: candidates,
        release_id: release.id
      }
    else
      {:error, :missing_date} -> %{status: "missing_date", release_id: release.id}
      false -> %{status: "before_effective_date", release_id: release.id}
      :error -> %{status: "rate_unavailable", release_id: release.id}
      [] -> %{status: "no_rule", release_id: release.id}
    end
  end

  defp matching_rules(code, rules) when is_binary(code) do
    rules
    |> Enum.filter(&explicit_match?(&1, code))
    |> Enum.reject(&excluded?(&1, code))
  end

  defp matching_rules(_code, _rules), do: []

  defp explicit_match?(rule, code) do
    scope = rule.parsed_scope
    Enum.any?(scope["includes"], &String.starts_with?(code, &1)) or range_match?(scope, code)
  end

  defp excluded?(rule, code) do
    Enum.any?(rule.parsed_scope["excludes"], &String.starts_with?(code, &1))
  end

  defp range_match?(scope, code) do
    Enum.any?(scope["ranges"], fn [first, last] ->
      prefix = String.slice(code, 0, String.length(first))
      String.length(first) == String.length(last) and prefix >= first and prefix <= last
    end)
  end

  defp candidates(rules, release) do
    rules
    |> Enum.sort_by(&{-rule_specificity(&1), &1.schedule, &1.serial_number})
    |> Enum.map(fn rule ->
      %{
        rate: Decimal.to_float(rule.total_rate),
        schedule: rule.schedule,
        serial_number: rule.serial_number,
        code_expression: rule.raw_code_expression,
        description: rule.raw_description,
        confidence: rule.parser_confidence,
        notification_number: release.notification_number,
        effective_from: Date.to_iso8601(release.effective_from)
      }
    end)
    |> Enum.uniq_by(&{&1.rate, &1.schedule, &1.serial_number})
  end

  defp rule_specificity(rule) do
    scope = rule.parsed_scope

    (scope["includes"] ++ Enum.flat_map(scope["ranges"], & &1))
    |> Enum.map(&String.length/1)
    |> Enum.max(fn -> 0 end)
  end

  defp invoice_date(%Date{} = date), do: {:ok, date}

  defp invoice_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, :missing_date}
    end
  end

  defp invoice_date(_value), do: {:error, :missing_date}

  defp message(line, index, validation),
    do: line_reason(line, index, validation) <> " " <> @correction_advice

  # The finding and the advice are separate because a merged issue states each
  # line's finding and then says once what to do about all of them; repeating
  # the caveat per line would bury the lines it is about.
  defp line_reason(line, index, validation) do
    [candidate | _] = validation["candidates"]
    rates = Enum.map_join(validation["candidate_rates"], ", ", &rate_label/1)

    strength =
      if validation["status"] == "incompatible", do: "does not match", else: "may not match"

    "Line #{index} \"#{line["description"] || "unnamed item"}\": printed HSN " <>
      "#{line["hsn_sac"]} at #{rate_label(validation["printed_rate"])} #{strength} " <>
      "the statutory candidate #{rates}. Based on #{candidate["notification_number"]}, " <>
      "Schedule #{candidate["schedule"]}, entry #{candidate["serial_number"]}, effective " <>
      "#{candidate["effective_from"]}."
  end

  defp issue_code("incompatible"), do: "statutory_rate_mismatch"
  defp issue_code("review"), do: "statutory_rate_review"

  defp rate_label(rate) when rate == trunc(rate), do: "#{trunc(rate)}%"
  defp rate_label(rate), do: "#{rate}%"

  defp stringify(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify(nested)} end)
  end

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value), do: value
end
