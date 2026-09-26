defmodule Nila.Gst.Sales.Excel.TableReader do
  @moduledoc "Finds a table by its headings and keeps physical cell coordinates."
  alias Nila.Gst.Sales.Excel.{TablePlan, Workbook}

  @spec matches?(map(), TablePlan.t()) :: boolean()
  def matches?(sheet, %TablePlan{} = plan) do
    Enum.any?(Enum.take(sheet.rows, plan.max_header_row), fn row ->
      case bind(row.cells, plan) do
        {:ok, _} -> true
        _ -> false
      end
    end)
  end

  @spec read!(map(), TablePlan.t()) :: map()
  def read!(sheet, %TablePlan{} = plan) do
    candidates =
      sheet.rows
      |> Enum.filter(&(&1.row <= plan.max_header_row))
      |> Enum.map(fn row -> {row, bind(row.cells, plan)} end)

    case Enum.find(candidates, fn {_, result} -> match?({:ok, _}, result) end) do
      {header, {:ok, columns}} ->
        rows =
          sheet.rows
          |> Enum.filter(&(&1.row > header.row))
          |> Enum.reject(fn row -> Enum.all?(Map.values(row.cells), &(&1 in [nil, ""])) end)
          |> Enum.map(fn row ->
            if blank_row?(row, columns) and
                 Enum.any?(Map.values(row.cells), &(&1 not in [nil, ""])) do
              fail(sheet.name, row.row, "Unrecognized data below the table headings.")
            end

            %{
              source: row,
              values: Map.new(columns, fn {field, column} -> {field, row.cells[column]} end)
            }
          end)

        %{
          header: header,
          columns: columns,
          rows: rows,
          plan: %{"id" => plan.id || Atom.to_string(plan.kind), "version" => plan.version}
        }

      nil ->
        if Enum.any?(candidates, fn {_, result} -> match?({:error, :ambiguous}, result) end),
          do: fail(sheet.name, 1, "Ambiguous #{plan.kind} headings."),
          else: fail(sheet.name, 1, "#{plan.kind} columns are missing.")
    end
  end

  @doc "Requires each repeated document field to have one distinct nonblank value."
  @spec require_agreement!([map()], [String.t()], [String.t()], String.t()) :: :ok
  def require_agreement!(rows, identity, fields, sheet_name) do
    rows
    |> Enum.group_by(fn row -> Enum.map(identity, &(row["values"][&1] || row[&1])) end)
    |> Enum.each(fn {_key, group} ->
      Enum.each(fields, fn field ->
        distinct =
          group
          |> Enum.map(& &1["values"][field])
          |> Enum.reject(&(&1 in [nil, ""]))
          |> Enum.uniq()

        if length(distinct) > 1 do
          source_rows = group |> Enum.map(& &1["row"]) |> Enum.join(", ")
          fail(sheet_name, hd(group)["row"], "Conflicting #{field} across rows #{source_rows}.")
        end
      end)
    end)

    :ok
  end

  defp bind(cells, %TablePlan{} = plan) do
    result =
      Map.new(plan.fields, fn {field, labels} ->
        labels = Enum.map(labels, &key/1)

        matches =
          Enum.filter(cells, fn {column, value} ->
            (is_nil(plan.max_column) or Workbook.column_index(column) <= plan.max_column) and
              key(value) in labels
          end)

        {field, matches}
      end)

    cond do
      Enum.any?(result, fn {_, matches} -> length(matches) > 1 end) ->
        {:error, :ambiguous}

      Enum.any?(plan.required, fn field -> result[field] == [] end) ->
        {:error, :missing}

      true ->
        {:ok,
         Map.new(result, fn {field, matches} ->
           column =
             case matches do
               [{column, _}] -> column
               [] -> nil
             end

           {field, column}
         end)}
    end
  end

  defp blank_row?(row, columns) do
    columns
    |> Map.values()
    |> Enum.reject(&is_nil/1)
    |> Enum.all?(&(row.cells[&1] in [nil, ""]))
  end

  defp key(value) when is_binary(value),
    do: value |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")

  defp key(_), do: ""
  defp fail(sheet, row, message), do: throw({:report_error, "#{sheet}, row #{row}: #{message}"})
end
