defmodule Nila.Gst.Sales.Excel.ReportPacket do
  @moduledoc "Validates a set of section files before reading them as one GSTR-1 report."

  alias Nila.Gst.Sales.Excel.{CsvWorkbook, Workbook}

  @max_files 20
  @max_total_bytes 25_000_000
  @extensions ~w(.xls .xlsx .csv)
  @section_names ~w(b2b b2b,sez,de b2cl b2cs cdnr cdnur exp at atadj exemp hsn docs) ++
                   ["hsn(b2b)", "hsn(b2c)"]
  @context_names ["gstr1 report", "gstr1"]

  def prepare(files) when is_list(files) do
    with :ok <- validate_files(files),
         files <- Enum.uniq_by(files, &digest(&1.bytes)),
         {:ok, sheets} <- read_sheets(files),
         :ok <- check_sections(sheets),
         workbook = %{sheets: Enum.map(sheets, & &1.sheet), date1904?: false},
         true <- Enum.any?(sheets, &(String.downcase(&1.sheet.name) in @section_names)) do
      {:ok, {files, workbook}}
    else
      false ->
        {:error,
         "These files are not a supported GSTR-1 section packet. Upload the B2B, B2CS, notes and HSN section files together; keep ProductWise reports separate."}

      error ->
        error
    end
  end

  def prepare(_), do: {:error, :invalid_file}

  defp validate_files(files) do
    cond do
      files == [] ->
        {:error, "Choose at least one sales report file."}

      length(files) > @max_files ->
        {:error, "Choose no more than 20 sales report files."}

      not Enum.all?(files, &valid_file?/1) ->
        {:error, :invalid_file}

      Enum.any?(files, &(byte_size(&1.bytes) > 5_000_000)) ->
        {:error, :too_large}

      Enum.sum(Enum.map(files, &byte_size(&1.bytes))) > @max_total_bytes ->
        {:error, "The sales report files must be 25 MB or less in total."}

      true ->
        :ok
    end
  end

  defp valid_file?(%{bytes: bytes, filename: filename}) do
    is_binary(bytes) and byte_size(bytes) > 0 and is_binary(filename) and
      String.downcase(Path.extname(filename)) in @extensions
  end

  defp valid_file?(_), do: false

  defp read_sheets(files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
      filename = Path.basename(file.filename)

      decoded =
        if String.downcase(Path.extname(filename)) == ".csv",
          do: CsvWorkbook.read(file.bytes, csv_section_name(filename)),
          else: Workbook.read(file.bytes)

      case decoded do
        {:ok, workbook} ->
          sheets =
            Enum.map(workbook.sheets, fn sheet ->
              %{sheet: Map.put(sheet, :source_filename, filename), filename: filename}
            end)

          {:cont, {:ok, acc ++ sheets}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp csv_section_name(filename) do
    case String.downcase(Path.rootname(filename)) do
      "b2b-1" -> "B2B"
      name when name in @section_names -> String.upcase(name)
      _ -> "B2B"
    end
  end

  defp check_sections(sheets) do
    cond do
      Enum.any?(sheets, & &1.sheet.hidden?) ->
        {:error, "Hidden report sheets are not supported."}

      Enum.any?(sheets, fn %{sheet: sheet, filename: filename} ->
        String.contains?(String.downcase(filename), "productwise") or
            String.contains?(String.downcase(sheet.name), "productwise")
      end) ->
        {:error,
         "ProductWise reports cannot be combined with GSTR-1 section files. Upload the GST section exports only."}

      Enum.any?(sheets, fn %{sheet: sheet} ->
        String.downcase(sheet.name) not in (@section_names ++ @context_names)
      end) ->
        {:error,
         "This packet contains an unrecognized sheet. Upload only GSTR-1 section exports."}

      true ->
        populated =
          Enum.filter(sheets, fn %{sheet: sheet} ->
            String.downcase(sheet.name) in @section_names and populated?(sheet)
          end)

        case populated
             |> Enum.group_by(&section_key/1)
             |> Enum.find(fn {_, group} -> length(group) > 1 end) do
          {section, _} ->
            {:error,
             "The #{String.upcase(section)} section has entries in more than one file. Choose one section export to avoid counting it twice."}

          nil ->
            :ok
        end
    end
  end

  defp populated?(sheet) do
    header =
      Enum.find(sheet.rows, fn row ->
        values = Enum.map(Map.values(row.cells), &to_string/1)

        Enum.any?(
          values,
          &(&1 in [
              "Taxable Value",
              "Invoice Number",
              "Note Number",
              "HSN",
              "Type",
              "Nature of Document"
            ])
        )
      end)

    header && Enum.any?(sheet.rows, &(&1.row > header.row))
  end

  defp section_key(%{sheet: %{name: name}, filename: filename}) do
    if String.downcase(name) == "hsn" do
      case String.downcase(filename) do
        "hsn(b2b)" <> _ -> "hsn(b2b)"
        "hsn(b2c)" <> _ -> "hsn(b2c)"
        _ -> "hsn"
      end
    else
      String.downcase(name)
    end
  end

  def digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
