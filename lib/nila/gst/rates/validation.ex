defmodule Nila.Gst.Rates.Validation do
  @moduledoc "Matches HSN goods to effective-dated candidates; SAC and description-only Any Chapter rules remain unchecked."

  alias Nila.Gst.LineRate

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

  defp annotate_line(%{"hsn_kind" => "hsn"} = line, invoice_date, directory) do
    validation = validate(line, invoice_date, directory)
    Map.put(line, "rate_validation", stringify(validation))
  end

  defp annotate_line(line, _invoice_date, _directory), do: line

  defp validate(line, invoice_date, directory) do
    release = directory.release

    with {:ok, date} <- invoice_date(invoice_date),
         true <- Date.compare(date, release.effective_from) != :lt,
         {:ok, printed_rate, rate_source} <- LineRate.line_rate_with_source(line),
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
