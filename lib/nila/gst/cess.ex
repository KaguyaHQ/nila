defmodule Nila.Gst.Cess do
  @moduledoc """
  Sales lines whose HSN falls under a cess-bearing tariff heading.

  Notification 02/2025-Compensation Cess (Rate), effective 22 September 2025,
  cut cess down to tobacco and pan masala. Notification 03/2025, effective
  1 February 2026, made the remaining compensation-cess rates nil.
  Historical screening and source preservation do not establish ITC eligibility.

  Sources: GST Council September 2025 FAQ and December 2025 newsletter:
  https://gstcouncil.gov.in/sites/default/files/2026-01/monthly_newsletter_december_2025_1.pdf

  Nila does not yet validate legacy cess claims or deferrals. Non-zero source
  cess remains evidence; ordinary purchase treatment cannot claim or defer it.
  """

  @reform ~D[2025-09-22]
  @withdrawal ~D[2026-02-01]

  # Headings 2401/2402/2403 are tobacco end to end, so four digits cannot
  # over-match. Pan masala takes its full eight: 2106 is "food preparations not
  # elsewhere specified", and a shorter prefix would flag the grocery trade.
  @tobacco ~w(2401 2402 2403 21069020)

  # Withdrawn by 02/2025, still live for earlier periods: aerated and caffeinated
  # beverages, coal, cars and SUVs, aircraft, yachts. Motorcycles take six digits
  # because the cess ran over 350cc and 8711 is every two-wheeler in the country.
  @pre_reform ~w(2202 2701 2702 2703 8703 871130 871140 871150 871190 8802 8903)

  @doc "One-based `%{line:, description:, hsn:}` per cess-candidate line."
  def hits(invoice) do
    prefixes = prefixes(invoice["invoice_date"])

    invoice["line_items"]
    |> List.wrap()
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, index} ->
      code = digits(line["hsn_sac"])

      if code != "" and Enum.any?(prefixes, &String.starts_with?(code, &1)),
        do: [%{line: index, description: line["description"], hsn: code}],
        else: []
    end)
  end

  # An unreadable date screens against both eras rather than assuming the
  # narrower one; the date carries its own issue already.
  defp prefixes(%Date{} = date) do
    cond do
      Date.compare(date, @withdrawal) != :lt -> []
      Date.compare(date, @reform) == :lt -> @tobacco ++ @pre_reform
      true -> @tobacco
    end
  end

  defp prefixes(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> prefixes(date)
      _ -> @tobacco ++ @pre_reform
    end
  end

  defp prefixes(_unreadable), do: @tobacco ++ @pre_reform

  @doc "Source warning, not a decision on historical cess entitlement."
  def purchase_issue(date, heads) do
    if (Map.get(heads || %{}, "cess") || 0) != 0 do
      basis =
        case date_value(date) do
          %Date{} = date ->
            if Date.compare(date, @withdrawal) != :lt,
              do:
                "Compensation cess on this document needs review; rates were nil from 1 February 2026.",
              else: "Historical compensation cess needs separate review."

          _ ->
            "Check the invoice date and the compensation cess amount."
        end

      basis <> " Nila does not claim or defer cess. The source amount is retained."
    end
  end

  @doc "Reject unsupported cess claim/deferral, including a tampered split payload."
  def validate_treatment(amounts) do
    if Enum.any?(~w(claim later), &((get_in(amounts, [&1, "cess"]) || 0) != 0)),
      do: {:error, :cess_review_required},
      else: :ok
  end

  defp date_value(%Date{} = date), do: date

  defp date_value(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp date_value(_), do: nil

  defp digits(value) when is_binary(value), do: String.replace(value, ~r/\D/, "")
  defp digits(_value), do: ""
end
