defmodule Nila.Gst.Cess do
  @moduledoc """
  Sales lines whose HSN falls under a cess-bearing tariff heading.

  Notification 02/2025-Compensation Cess (Rate), effective 22 September 2025,
  cut cess down to tobacco and pan masala. Screening the codes means a month
  with nothing cess-bearing asks the reviewer nothing.
  """

  @reform ~D[2025-09-22]

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
    if Date.compare(date, @reform) == :lt, do: @tobacco ++ @pre_reform, else: @tobacco
  end

  defp prefixes(_unreadable), do: @tobacco ++ @pre_reform

  defp digits(value) when is_binary(value), do: String.replace(value, ~r/\D/, "")
  defp digits(_value), do: ""
end
