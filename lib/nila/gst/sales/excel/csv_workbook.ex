defmodule Nila.Gst.Sales.Excel.CsvWorkbook do
  @moduledoc "Reads a bounded UTF-8 CSV as one worksheet with source row numbers."

  @max_bytes 5_000_000
  @max_rows 5_001
  @max_columns 100

  def read(bytes, sheet_name \\ "B2B")

  def read(bytes, sheet_name)
      when is_binary(bytes) and is_binary(sheet_name) and byte_size(bytes) <= @max_bytes do
    bytes = String.trim_leading(bytes, <<0xEF, 0xBB, 0xBF>>)

    if String.valid?(bytes) and :binary.match(bytes, <<0>>) == :nomatch and
         byte_size(sheet_name) in 1..31 do
      rows = NimbleCSV.RFC4180.parse_string(bytes, skip_headers: false)

      cond do
        rows == [] ->
          {:error, :invalid_file}

        length(rows) > @max_rows or Enum.any?(rows, &(length(&1) > @max_columns)) ->
          {:error, :too_large}

        true ->
          rows =
            rows
            |> Enum.with_index(1)
            |> Enum.map(fn {values, number} ->
              cells =
                values
                |> Enum.with_index(1)
                |> Map.new(fn {value, index} -> {column_name(index), String.trim(value)} end)

              %{row: number, cells: cells}
            end)
            |> Enum.reject(fn row -> Enum.all?(Map.values(row.cells), &(&1 == "")) end)

          {:ok, %{sheets: [%{name: sheet_name, hidden?: false, rows: rows}], date1904?: false}}
      end
    else
      {:error, :invalid_file}
    end
  rescue
    NimbleCSV.ParseError -> {:error, :invalid_file}
  end

  def read(bytes, _) when is_binary(bytes) and byte_size(bytes) > @max_bytes,
    do: {:error, :too_large}

  def read(_, _), do: {:error, :invalid_file}

  defp column_name(index) do
    index
    |> Stream.unfold(fn
      0 -> nil
      n -> {rem(n - 1, 26) + ?A, div(n - 1, 26)}
    end)
    |> Enum.reverse()
    |> List.to_string()
  end
end
