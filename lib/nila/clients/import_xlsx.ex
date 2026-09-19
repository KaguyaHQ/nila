defmodule Nila.Clients.ImportXlsx do
  @moduledoc false
  require Record
  Record.defrecordp(:zip_file, Record.extract(:zip_file, from_lib: "stdlib/include/zip.hrl"))
  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  @max_bytes 2_000_000
  @max_expanded 10_000_000
  @max_rows 1000
  def max_bytes, do: @max_bytes
  def max_rows, do: @max_rows

  def read(bytes) when is_binary(bytes) and byte_size(bytes) <= @max_bytes do
    with {:ok, entries} <- :zip.table(bytes),
         :ok <- check_size(entries),
         {:ok, files} <- :zip.extract(bytes, [:memory]) do
      files = Map.new(files, fn {path, value} -> {to_string(path), value} end)
      workbook = xml(Map.fetch!(files, "xl/workbook.xml"))
      sheets = nodes(workbook, "sheet")
      if length(sheets) != 1, do: throw(:multiple_sheets)
      sheet = hd(sheets)
      rels = xml(Map.fetch!(files, "xl/_rels/workbook.xml.rels"))

      relationship =
        Enum.find(nodes(rels, "Relationship"), &(&1.attrs["Id"] == sheet.attrs["id"]))

      if is_nil(relationship) or relationship.attrs["TargetMode"] == "External",
        do: throw(:invalid_file)

      target = relationship.attrs["Target"]

      path =
        if String.starts_with?(target, "/"),
          do: String.trim_leading(target, "/"),
          else: "xl/" <> target

      if Enum.any?(String.split(path, "/"), &(&1 in ["..", "."])), do: throw(:invalid_file)

      shared =
        case files["xl/sharedStrings.xml"] do
          nil -> {}
          data -> data |> xml() |> nodes("si") |> Enum.map(&text/1) |> List.to_tuple()
        end

      rows =
        files
        |> Map.fetch!(path)
        |> xml()
        |> nodes("row")
        |> Enum.with_index(1)
        |> Enum.map(fn {row, index} ->
          cells =
            Map.new(nodes(row, "c"), fn cell ->
              column = Regex.replace(~r/\d+$/, cell.attrs["r"] || "", "")
              {column, value(cell, shared)}
            end)

          %{row: String.to_integer(row.attrs["r"] || to_string(index)), cells: cells}
        end)
        |> Enum.reject(fn row -> Enum.all?(Map.values(row.cells), &(&1 in [nil, ""])) end)

      parse_rows(rows, sheet.attrs["name"])
    else
      {:error, :too_large} -> {:error, :too_large}
      _ -> {:error, :invalid_file}
    end
  rescue
    _ -> {:error, :invalid_file}
  catch
    reason when reason in [:multiple_sheets, :too_many_rows, :invalid_file] -> {:error, reason}
    _ -> {:error, :invalid_file}
  end

  def read(_), do: {:error, :too_large}

  defp check_size(entries) do
    sizes = for zip_file(info: info) <- entries, do: file_info(info, :size)

    if length(entries) <= 200 and Enum.sum(sizes) <= @max_expanded,
      do: :ok,
      else: {:error, :too_large}
  end

  defp parse_rows([], _sheet), do: {:error, :empty_file}

  defp parse_rows([header | rows], sheet) do
    names =
      Enum.filter(header.cells, fn {_column, value} ->
        header(value) in ["clientname", "name", "client"]
      end)

    gstins =
      Enum.filter(header.cells, fn {_column, value} ->
        header(value) in ["gstin", "gstnumber", "gstno"]
      end)

    usernames =
      Enum.filter(header.cells, fn {_column, value} ->
        header(value) in ["gstusername", "gstportalusername"]
      end)

    case {names, gstins, usernames} do
      {[{name_col, _}], [{gstin_col, _}], [{username_col, _}]} ->
        rows =
          Enum.map(rows, fn row ->
            %{
              row: row.row,
              name: row.cells[name_col] || "",
              gstin: row.cells[gstin_col] || "",
              gst_username: row.cells[username_col] || ""
            }
          end)
          |> Enum.reject(&(&1.name == "" and &1.gstin == "" and &1.gst_username == ""))

        cond do
          length(rows) > @max_rows -> {:error, :too_many_rows}
          rows == [] -> {:error, :empty_file}
          true -> {:ok, %{sheet: sheet, rows: rows}}
        end

      _ ->
        {:error, :headers}
    end
  end

  defp header(value) when is_binary(value),
    do: value |> String.downcase() |> String.replace(~r/[^a-z]/, "")

  defp header(_), do: ""

  defp value(cell, shared) do
    cond do
      nodes(cell, "f") != [] ->
        :formula

      cell.attrs["t"] == "s" ->
        index = cell |> nodes("v") |> Enum.map_join(&text/1) |> String.to_integer()
        elem(shared, index) |> String.trim()

      cell.attrs["t"] == "inlineStr" ->
        cell |> nodes("is") |> Enum.map_join(&text/1) |> String.trim()

      cell.attrs["t"] in ["e", "b"] ->
        :invalid_cell

      true ->
        cell |> nodes("v") |> Enum.map_join(&text/1) |> String.trim()
    end
  end

  # SAX keeps uploaded XML names as strings rather than creating BEAM atoms.
  # XLSX needs no DTDs or external entities.
  defp xml(bytes) do
    if not String.valid?(bytes) or :binary.match(bytes, <<0>>) != :nomatch or
         Regex.match?(~r/<!DOCTYPE|<!ENTITY/i, bytes),
       do: throw(:invalid_file)

    case :xmerl_sax_parser.stream(bytes, event_fun: &event/3, event_state: []) do
      {:ok, [root], rest} when is_binary(rest) ->
        if String.trim(rest) != "", do: throw(:invalid_file)
        root

      _ ->
        throw(:invalid_file)
    end
  end

  defp event({:startElement, _uri, name, _qname, attrs}, _, stack) do
    if length(stack) > 32, do: throw(:invalid_file)

    attrs =
      Map.new(attrs, fn {_uri, _prefix, key, value} -> {to_string(key), to_string(value)} end)

    [%{tag: to_string(name), attrs: attrs, children: []} | stack]
  end

  defp event({:endElement, _, _, _}, _, [node, parent | rest]),
    do: [
      %{parent | children: [%{node | children: Enum.reverse(node.children)} | parent.children]}
      | rest
    ]

  defp event({:endElement, _, _, _}, _, [node]),
    do: [%{node | children: Enum.reverse(node.children)}]

  defp event({:characters, chars}, _, [node | rest]),
    do: [%{node | children: [to_string(chars) | node.children]} | rest]

  defp event(_, _, state), do: state

  defp nodes(%{children: children} = node, tag),
    do: if(node.tag == tag, do: [node], else: []) ++ Enum.flat_map(children, &nodes(&1, tag))

  defp nodes(_, _), do: []
  defp text(%{children: children}), do: Enum.map_join(children, &text/1)
  defp text(value) when is_binary(value), do: value
end
