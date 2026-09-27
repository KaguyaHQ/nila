defmodule Nila.Gst.Sales.SourceSpreadsheet do
  @moduledoc "Original spreadsheet rows and invoice links for the sales reviewer."

  alias Nila.Gst.Sales.Excel.{CsvWorkbook, Workbook}
  alias Nila.Gst.Sales.Invoice
  alias Nila.Gst.Sales.SourceSpreadsheet.Cache
  alias Nila.Storage

  @extensions ~w(.xls .xlsx .csv)

  def available?(dump) do
    dump.meta["excel_import"] == true and
      dump.file_keys != [] and
      Enum.all?(dump.file_keys, &(String.downcase(Path.extname(&1)) in @extensions))
  end

  def refs(invoice, dump) do
    case invoice["source_refs"] do
      refs when is_list(refs) and refs != [] ->
        refs
        |> Enum.map(fn ref ->
          if is_map(ref) and is_nil(ref["source_filename"]),
            do: Map.put(ref, "source_filename", invoice["source_filename"] || filename(dump, 0)),
            else: ref
        end)
        |> Enum.filter(&valid_ref?/1)
        |> Enum.group_by(&{&1["source_filename"], &1["sheet"]}, & &1["row"])
        |> Enum.map(fn {{file, sheet}, rows} ->
          %{file: file, sheet: sheet, rows: Enum.uniq(rows)}
        end)

      _ ->
        rows = Enum.filter(invoice["source_rows"] || [], &(is_integer(&1) and &1 > 0))
        sheet = invoice["source_sheet"] || dump.meta["excel_sheet"]
        file = invoice["source_filename"] || filename(dump, 0)

        if rows != [] and is_binary(sheet) and is_binary(file),
          do: [%{file: file, sheet: sheet, rows: rows}],
          else: []
    end
  end

  def load(dump, invoices, selected, requested_file, requested_sheet) do
    with true <- available?(dump),
         files = file_descriptors(dump),
         %{name: file, index: index, key: key} <- choose_file(files, selected, requested_file),
         {:ok, workbook} <- read_file(dump, key, index, file),
         sheet <- choose_sheet(workbook, file, selected, requested_sheet),
         %{rows: rows} <- Enum.find(workbook.sheets, &(&1.name == sheet)) do
      refs =
        for invoice <- invoices,
            ref <- refs(invoice, dump),
            ref.file == file and ref.sheet == sheet,
            row <- ref.rows,
            reduce: %{} do
          acc ->
            Map.update(acc, row, [Invoice.source_id(invoice)], &[Invoice.source_id(invoice) | &1])
        end

      columns =
        rows
        |> Enum.flat_map(&Map.keys(&1.cells))
        |> Enum.uniq()
        |> Enum.sort_by(&Workbook.column_index/1)

      report_row =
        get_in(dump.meta, ["return_report", "rows"])
        |> List.wrap()
        |> Enum.find(&(&1["source_filename"] == file and &1["sheet"] == sheet))

      mapping =
        cond do
          is_map(report_row) -> report_row["columns"] || %{}
          dump.meta["excel_sheet"] == sheet -> dump.meta["excel_mapping"] || %{}
          true -> %{}
        end

      relevant_fields =
        if report_row,
          do: ~w(buyer_name number date value rate txval iamt camt samt csamt),
          else: Map.keys(mapping)

      relevant_columns =
        relevant_fields
        |> Enum.map(&mapping[&1])
        |> Enum.filter(&(&1 in columns))
        |> Enum.uniq()
        |> Enum.sort_by(&Workbook.column_index/1)

      header =
        if report_row,
          do:
            Enum.find_value(rows, fn row -> if row.cells == report_row["headers"], do: row.row end),
          else: dump.meta["excel_header"]

      header_rows =
        if is_integer(header) and header > 0 and (report_row || dump.meta["excel_sheet"] == sheet),
          do: [header],
          else: []

      {:ok,
       %{
         files:
           Enum.map(
             files,
             fn source ->
               sheets =
                 if source.name == file,
                   do: Enum.map(workbook.sheets, & &1.name),
                   else: source.sheets

               %{name: source.name, sheets: sheets}
             end
           ),
         file: file,
         sheet: sheet,
         columns: columns,
         rows:
           Enum.map(
             rows,
             &%{
               row: &1.row,
               cells: display_cells(&1.cells),
               invoice_ids: refs |> Map.get(&1.row, []) |> Enum.uniq()
             }
           ),
         relevant_columns: relevant_columns,
         header_rows: header_rows,
         invoice_column: mapping["number"] || mapping["invoice_number"],
         download_url: "/gst/#{dump.client_id}/#{dump.period}/original/#{dump.id}/#{index}"
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  defp valid_ref?(%{"source_filename" => file, "sheet" => sheet, "row" => row}),
    do: is_binary(file) and is_binary(sheet) and is_integer(row) and row > 0

  defp valid_ref?(_), do: false

  defp file_descriptors(dump) do
    report_rows = get_in(dump.meta, ["return_report", "rows"]) |> List.wrap()

    dump.file_keys
    |> Enum.with_index()
    |> Enum.map(fn {key, index} ->
      name = filename(dump, index)

      sheets =
        report_rows
        |> Enum.filter(&(&1["source_filename"] == name))
        |> Enum.map(& &1["sheet"])
        |> Enum.filter(&is_binary/1)
        |> Enum.uniq()

      %{key: key, index: index, name: name, sheets: sheets}
    end)
  end

  defp read_file(dump, key, index, name) do
    manifest = get_in(dump.meta, ["file_manifest"]) |> List.wrap() |> Enum.at(index)
    digest = if is_map(manifest), do: manifest["sha256"], else: dump.meta["excel_sha256"]
    identity = {dump.org_id, dump.id, key, digest}

    Cache.fetch(identity, fn ->
      with {:ok, bytes} <- Storage.get(key), do: decode(bytes, name)
    end)
  end

  defp filename(dump, index) do
    case get_in(dump.meta, ["file_manifest"]) do
      manifest when is_list(manifest) ->
        case Enum.at(manifest, index) do
          %{"filename" => name} when is_binary(name) -> Path.basename(name)
          _ -> Path.basename(Enum.at(dump.file_keys, index))
        end

      _ ->
        dump.meta["original_name"] || Path.basename(Enum.at(dump.file_keys, index))
    end
  end

  defp decode(bytes, name) do
    if String.downcase(Path.extname(name)) == ".csv" do
      CsvWorkbook.read(bytes, csv_sheet_name(name))
    else
      Workbook.read(bytes)
    end
  end

  defp csv_sheet_name(name) do
    case String.downcase(Path.rootname(name)) do
      "b2b-1" -> "B2B"
      section -> String.upcase(section)
    end
  end

  defp choose_file(files, selected, requested_file) do
    default = List.first(selected) || %{}
    file = requested_file || default[:file] || hd(files).name
    Enum.find(files, &(&1.name == file))
  end

  defp choose_sheet(workbook, file, selected, requested_sheet) do
    default = List.first(selected) || %{}
    first_sheet = workbook.sheets |> List.first() |> then(&(&1 && &1.name))
    sheet = requested_sheet || if(file == default[:file], do: default[:sheet]) || first_sheet
    if Enum.any?(workbook.sheets, &(&1.name == sheet)), do: sheet
  end

  defp display_cells(cells) do
    Map.new(cells, fn {column, value} ->
      {column,
       case value do
         :formula -> "[Formula]"
         :invalid_cell -> "[Cell error]"
         nil -> ""
         other -> to_string(other)
       end}
    end)
  end
end
