defmodule Nila.Gst.Hsn.Xlsx do
  @moduledoc false

  require Record

  Record.defrecordp(
    :xmlElement,
    Record.extract(:xmlElement, from_lib: "xmerl/include/xmerl.hrl")
  )

  Record.defrecordp(
    :xmlAttribute,
    Record.extract(:xmlAttribute, from_lib: "xmerl/include/xmerl.hrl")
  )

  Record.defrecordp(:xmlText, Record.extract(:xmlText, from_lib: "xmerl/include/xmerl.hrl"))

  @sheets [
    {"xl/worksheets/sheet1.xml", "HSN_CD", "HSN_Description", "hsn"},
    {"xl/worksheets/sheet2.xml", "SAC_CD", "SAC_Description", "sac"}
  ]

  def read(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, files} <- :zip.extract(bytes, [:memory]),
         files = Map.new(files, fn {name, contents} -> {to_string(name), contents} end),
         {:ok, shared_xml} <- Map.fetch(files, "xl/sharedStrings.xml") do
      shared_strings = shared_strings(shared_xml)

      Enum.reduce_while(@sheets, {:ok, []}, fn {sheet, code_header, desc_header, kind},
                                               {:ok, entries} ->
        with {:ok, sheet_xml} <- Map.fetch(files, sheet),
             {:ok, parsed} <-
               parse_sheet(sheet_xml, shared_strings, code_header, desc_header, kind) do
          {:cont, {:ok, entries ++ parsed}}
        else
          :error -> {:halt, {:error, {:missing_sheet, sheet}}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    else
      :error -> {:error, :shared_strings_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp shared_strings(xml) do
    xml
    |> document()
    |> xpath("//*[local-name()='si']")
    |> Enum.map(&text_content/1)
  end

  defp parse_sheet(xml, shared_strings, code_header, desc_header, kind) do
    rows = xml |> document() |> xpath("//*[local-name()='sheetData']/*[local-name()='row']")

    case rows do
      [header | data_rows] ->
        headers = row_values(header, shared_strings)

        if headers["A"] == code_header and headers["B"] == desc_header do
          entries =
            data_rows
            |> Enum.map(&row_values(&1, shared_strings))
            |> Enum.reject(&blank_row?/1)
            |> Enum.map(&entry(&1, kind))

          case Enum.find(entries, &match?({:error, _}, &1)) do
            nil -> {:ok, Enum.map(entries, fn {:ok, parsed} -> parsed end)}
            {:error, reason} -> {:error, reason}
          end
        else
          {:error, {:unexpected_headers, kind, headers}}
        end

      [] ->
        {:error, {:empty_sheet, kind}}
    end
  end

  defp entry(row, kind) do
    code = normalize_code(row["A"], kind)
    description = normalize_description(row["B"])

    cond do
      code == "" -> {:error, {:missing_code, kind}}
      not Regex.match?(~r/^\d+$/, code) -> {:error, {:invalid_code, kind, row["A"]}}
      String.length(code) not in expected_lengths(kind) -> {:error, {:invalid_length, kind, code}}
      description == "" -> {:error, {:missing_description, kind, code}}
      true -> {:ok, %{code: code, description: description, kind: kind}}
    end
  end

  defp normalize_code(value, kind) do
    code = value |> to_string() |> String.replace(~r/\s+/, "")

    if kind == "hsn" and String.length(code) in [1, 3, 5, 7] and
         Regex.match?(~r/^\d+$/, code) do
      String.pad_leading(code, String.length(code) + 1, "0")
    else
      code
    end
  end

  defp expected_lengths("hsn"), do: [2, 4, 6, 8]
  defp expected_lengths("sac"), do: [2, 4, 6]

  defp normalize_description(value) do
    value
    |> to_string()
    |> String.replace("_x000D_", " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp blank_row?(row), do: row["A"] in [nil, ""] and row["B"] in [nil, ""]

  defp row_values(row, shared_strings) do
    row
    |> xpath("./*[local-name()='c']")
    |> Map.new(fn cell -> {column(cell), cell_value(cell, shared_strings)} end)
  end

  defp column(cell) do
    cell
    |> attribute(:r)
    |> to_string()
    |> String.replace(~r/\d+$/, "")
  end

  defp cell_value(cell, shared_strings) do
    value = cell |> xpath("./*[local-name()='v']") |> List.first()

    case {attribute(cell, :t) |> to_string(), value} do
      {"s", value} when not is_nil(value) ->
        Enum.at(shared_strings, String.to_integer(text_content(value)))

      {_type, nil} ->
        cell |> xpath("./*[local-name()='is']") |> Enum.map_join(&text_content/1)

      {_type, value} ->
        text_content(value)
    end
  end

  defp attribute(element, name) do
    element
    |> xmlElement(:attributes)
    |> Enum.find_value(fn attribute ->
      if xmlAttribute(attribute, :name) == name, do: xmlAttribute(attribute, :value)
    end)
  end

  defp text_content(xmlText(value: value)), do: to_string(value)

  defp text_content(xmlElement(content: content)) do
    Enum.map_join(content, &text_content/1)
  end

  defp text_content(_other), do: ""

  defp document(xml) do
    {document, _rest} = :xmerl_scan.string(:erlang.binary_to_list(xml), quiet: true)
    document
  end

  defp xpath(node, expression),
    do: :xmerl_xpath.string(String.to_charlist(expression), node)
end
