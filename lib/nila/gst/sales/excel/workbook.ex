defmodule Nila.Gst.Sales.Excel.Workbook do
  @moduledoc "Bounded XLSX reader retaining worksheet names, row numbers and cell types."
  require Record
  Record.defrecordp(:zip_file, Record.extract(:zip_file, from_lib: "stdlib/include/zip.hrl"))
  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  @max_bytes 5_000_000
  def max_bytes, do: @max_bytes

  def read(<<0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, _::binary>> = bytes)
      when byte_size(bytes) <= @max_bytes,
      do: Nila.Gst.Sales.Excel.LegacyWorkbook.read(bytes)

  def read(bytes) when is_binary(bytes) and byte_size(bytes) <= @max_bytes do
    with {:ok, entries} <- :zip.table(bytes),
         true <- length(entries) <= 300,
         sizes = for(zip_file(info: info) <- entries, do: file_info(info, :size)),
         true <- Enum.sum(sizes) <= 25_000_000,
         {:ok, extracted} <- :zip.extract(bytes, [:memory]) do
      files = Map.new(extracted, fn {path, data} -> {to_string(path), data} end)
      if map_size(files) != length(extracted), do: throw(:invalid_file)
      workbook = xml(Map.fetch!(files, "xl/workbook.xml"))
      rels = files |> Map.fetch!("xl/_rels/workbook.xml.rels") |> xml() |> nodes("Relationship")

      shared =
        case files["xl/sharedStrings.xml"] do
          nil -> {}
          data -> data |> xml() |> nodes("si") |> Enum.map(&text/1) |> List.to_tuple()
        end

      sheets = nodes(workbook, "sheet")
      if length(sheets) > 20, do: throw(:too_large)

      sheets =
        Enum.map(sheets, fn sheet ->
          rel = Enum.find(rels, &(&1.attrs["Id"] == sheet.attrs["id"]))
          if is_nil(rel) or rel.attrs["TargetMode"] == "External", do: throw(:invalid_file)
          target = rel.attrs["Target"]

          path =
            if String.starts_with?(target, "/"),
              do: String.trim_leading(target, "/"),
              else: "xl/" <> target

          if Enum.any?(String.split(path, "/"), &(&1 in ["..", "."])), do: throw(:invalid_file)
          rows = files |> Map.fetch!(path) |> xml() |> nodes("row")
          if length(rows) > 5001, do: throw(:too_large)

          rows =
            Enum.map(rows, fn row ->
              cells = nodes(row, "c")
              if length(cells) > 100, do: throw(:too_large)
              if Enum.uniq_by(cells, & &1.attrs["r"]) != cells, do: throw(:invalid_file)
              number = String.to_integer(row.attrs["r"])
              if number < 1 or number > 1_048_576, do: throw(:invalid_file)

              %{
                row: number,
                cells:
                  Map.new(cells, fn cell ->
                    column = Regex.replace(~r/\d+$/, cell.attrs["r"] || "", "")
                    if not Regex.match?(~r/\A[A-Z]{1,3}\z/, column), do: throw(:invalid_file)

                    if cell.attrs["r"] != column <> to_string(number) or
                         column_index(column) > 16_384,
                       do: throw(:invalid_file)

                    {column, value(cell, shared)}
                  end)
              }
            end)
            |> Enum.reject(fn row -> Enum.all?(Map.values(row.cells), &(&1 in [nil, ""])) end)

          if Enum.uniq_by(rows, & &1.row) != rows, do: throw(:invalid_file)

          if rows |> Enum.flat_map(&Map.keys(&1.cells)) |> Enum.uniq() |> length() > 100,
            do: throw(:too_large)

          %{
            name: sheet.attrs["name"],
            hidden?: sheet.attrs["state"] in ["hidden", "veryHidden"],
            rows: rows
          }
        end)

      date1904 =
        Enum.any?(nodes(workbook, "workbookPr"), &(&1.attrs["date1904"] in ["1", "true"]))

      {:ok, %{sheets: sheets, date1904?: date1904}}
    else
      false -> {:error, :too_large}
      _ -> {:error, :invalid_file}
    end
  rescue
    _ -> {:error, :invalid_file}
  catch
    reason when reason in [:invalid_file, :too_large] -> {:error, reason}
    _ -> {:error, :invalid_file}
  end

  def read(_), do: {:error, :too_large}

  def column_index(column),
    do: column |> String.to_charlist() |> Enum.reduce(0, &(&2 * 26 + &1 - ?A + 1))

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
