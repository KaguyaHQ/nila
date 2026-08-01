defmodule Nila.Gst.RateHistory do
  @moduledoc "Deterministic same-item GST-rate precedent checks."

  import Ecto.Query, only: [from: 2]

  alias Nila.Fuzzy
  alias Nila.Gst.Sales.Month
  alias Nila.Repo

  def prior_observations(org_id, client_id, period) do
    Repo.all(
      from m in Month,
        where: m.org_id == ^org_id and m.client_id == ^client_id and m.period < ^period,
        order_by: [desc: m.period],
        limit: 12,
        select: {m.period, m.invoices}
    )
    |> Enum.flat_map(fn {prior_period, invoices} -> observations(invoices, prior_period) end)
  end

  def issues(invoices, historical_observations \\ []) do
    current = observations(invoices, nil)
    groups = Enum.group_by(historical_observations ++ current, & &1.key)

    current
    |> Enum.group_by(& &1.invoice)
    |> Enum.flat_map(fn {invoice_number, invoice_observations} ->
      conflicts =
        Enum.filter(invoice_observations, fn observation ->
          groups[observation.key]
          |> Enum.map(& &1.rate)
          |> Enum.uniq()
          |> length() > 1
        end)

      if conflicts == [] do
        []
      else
        [conflict_issue(invoice_number, conflicts, groups)]
      end
    end)
  end

  def observations(invoices, period) do
    Enum.flat_map(invoices, fn invoice ->
      invoice["line_items"]
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.flat_map(fn {line, index} ->
        with code when is_binary(code) and code != "" <- line["hsn_sac"],
             description when description != "" <- Fuzzy.normalize(line["description"]),
             {:ok, rate} <- line_rate(line) do
          [
            %{
              key: {description, code},
              description: line["description"],
              code: code,
              rate: rate,
              invoice: invoice["invoice_number"],
              period: period,
              line_index: index
            }
          ]
        else
          _ -> []
        end
      end)
    end)
  end

  defp conflict_issue(invoice_number, conflicts, groups) do
    details =
      Enum.map_join(conflicts, " ", fn observation ->
        alternatives =
          groups[observation.key]
          |> Enum.reject(&same_observation?(&1, observation))
          |> Enum.reject(&(&1.rate == observation.rate))

        rates =
          alternatives |> Enum.map(&rate_label(&1.rate)) |> Enum.uniq() |> Enum.join(" and ")

        references =
          alternatives
          |> Enum.map(&reference(&1, observation))
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
          |> Enum.take(3)

        location =
          case references do
            [] -> "on other invoices"
            ["elsewhere on this invoice"] -> "elsewhere on this invoice"
            references -> "on " <> Enum.join(references, ", ")
          end

        "Line #{observation.line_index + 1} \"#{observation.description}\" uses HSN/SAC " <>
          "#{observation.code} at #{rate_label(observation.rate)}, but the same item and code " <>
          "also appears at #{rates} #{location}."
      end)

    %{
      "invoice" => invoice_number,
      "code" => "rate_history_conflict",
      "message" =>
        details <>
          " Confirm the applicable rate; this history check alone does not establish the legally applicable rate.",
      "fields" =>
        Enum.flat_map(conflicts, fn observation ->
          index = observation.line_index

          [
            "line_items[#{index}].cgst_rate",
            "line_items[#{index}].sgst_rate",
            "line_items[#{index}].igst_rate"
          ]
        end)
        |> Enum.uniq()
    }
  end

  def line_rate(line) do
    case line_rate_with_source(line) do
      {:ok, rate, _source} -> {:ok, rate}
      :error -> :error
    end
  end

  def line_rate_with_source(line) do
    values = [line["cgst_rate"], line["sgst_rate"], line["igst_rate"]]

    cond do
      Enum.any?(values, &is_number/1) ->
        rate = values |> Enum.map(&if(is_number(&1), do: &1, else: 0)) |> Enum.sum()
        {:ok, Float.round(rate * 1.0, 4), :printed}

      is_integer(line["taxable_paise"]) and line["taxable_paise"] > 0 and
          line_tax(line) > 0 ->
        rate = Float.round(line_tax(line) * 100 / line["taxable_paise"], 4)
        {:ok, rate, :derived}

      true ->
        :error
    end
  end

  defp line_tax(line) do
    line["tax_paise"] |> Map.values() |> Enum.sum()
  end

  defp same_observation?(left, right) do
    left.invoice == right.invoice and left.period == right.period and
      left.line_index == right.line_index and left.rate == right.rate
  end

  defp reference(%{invoice: nil}, _current), do: nil

  defp reference(%{period: nil, invoice: invoice}, %{period: nil, invoice: invoice}),
    do: "elsewhere on this invoice"

  defp reference(%{period: nil, invoice: invoice}, _current), do: "invoice #{invoice}"

  defp reference(%{period: period, invoice: invoice}, _current),
    do: "invoice #{invoice} (#{period})"

  defp rate_label(rate) when rate == trunc(rate), do: "#{trunc(rate)}%"
  defp rate_label(rate), do: "#{rate}%"
end
