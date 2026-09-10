defmodule Nila.Gst.Dates do
  @moduledoc "Parses printed invoice dates shared by sales and purchase intake."

  @doc """
  Parses printed invoice dates: `DD.MM.YYYY`, `DD/MM/YYYY`, `DD-MM-YYYY`,
  and `DD-Mon-YY`, with 1-2 digit day/month and 2 or 4 digit year.
  Returns `Date.t()` or nil; two-digit years are interpreted as 2000–2099.
  """
  def parse_date(nil), do: nil

  def parse_date(value) when is_binary(value) do
    case Date.from_iso8601(String.trim(value)) do
      {:ok, date} -> date
      {:error, _reason} -> parse_printed_date(value)
    end
  end

  defp parse_printed_date(value) do
    case Regex.run(~r/\b(\d{1,2})[.\/-](\d{1,2}|[a-z]{3})[.\/-](\d{4}|\d{2})\b/i, value) do
      [_, d, m, y] ->
        year = String.to_integer(y)
        year = if year < 100, do: 2000 + year, else: year

        case Date.new(year, printed_month(m), String.to_integer(d)) do
          {:ok, date} -> date
          {:error, _} -> nil
        end

      _ ->
        nil
    end
  end

  defp printed_month(value) do
    case Integer.parse(value) do
      {month, ""} ->
        month

      _ ->
        Enum.find_index(
          ~w(jan feb mar apr may jun jul aug sep oct nov dec),
          &(&1 == String.downcase(value))
        )
        |> case do
          nil -> 0
          index -> index + 1
        end
    end
  end
end
