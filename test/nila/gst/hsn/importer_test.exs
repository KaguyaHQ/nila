defmodule Nila.Gst.Hsn.ImporterTest do
  use Nila.DataCase, async: false

  alias Nila.Gst.Hsn.{Directory, Entry, Importer, Release}

  setup do
    path = Path.join(System.tmp_dir!(), "nila-hsn-#{System.unique_integer([:positive])}.xlsx")
    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  test "imports, normalizes, deduplicates and builds the code hierarchy", %{path: path} do
    write_workbook(path, "HORSES")

    assert {:ok, result} = Importer.import(path)
    assert result.source_rows == 8
    assert result.entries == 7
    assert result.duplicate_rows == 1
    assert result.diff == %{added: 7, removed: 0, descriptions_changed: 0}
    assert result.release.status == "staged"

    leaf = Repo.get_by!(Entry, release_id: result.release.id, kind: "hsn", code: "01011010")
    assert leaf.description == "HORSES"
    assert leaf.parent_code == "010110"
    refute leaf.has_children

    heading = Repo.get_by!(Entry, release_id: result.release.id, kind: "hsn", code: "0101")
    assert heading.parent_code == "01"
    assert heading.has_children

    assert {:error, :duplicate_release} = Importer.import(path)
  end

  test "activation leaves exactly one active immutable release", %{path: first_path} do
    write_workbook(first_path, "HORSES")
    {:ok, first} = Importer.import(first_path)
    assert {:ok, active_first} = Importer.activate(first.release.id)
    assert active_first.status == "active"

    second_path = first_path <> ".second"
    on_exit(fn -> File.rm(second_path) end)
    write_workbook(second_path, "PURE-BRED HORSES")

    {:ok, second} = Importer.import(second_path)
    assert second.diff.descriptions_changed == 1
    assert {:ok, active_second} = Importer.activate(second.release.id)

    assert Repo.reload!(active_first).status == "superseded"
    assert active_second.status == "active"
    assert Repo.aggregate(from(r in Release, where: r.status == "active"), :count) == 1

    assert {:ok, directory} = Directory.active()
    assert directory.release.id == active_second.id
    assert Directory.validate("01011010", directory).description == "PURE-BRED HORSES"
  end

  defp write_workbook(path, leaf_description) do
    hsn_rows = [
      {"HSN_CD", "HSN_Description"},
      {"01", "LIVE ANIMALS"},
      {"0101", "HORSES"},
      {"010110", "PURE-BRED BREEDING ANIMALS"},
      {"01011010", "A LONGER DUPLICATE HORSE DESCRIPTION"},
      {"1011010", leaf_description}
    ]

    sac_rows = [
      {"SAC_CD", "SAC_Description"},
      {"99", "ALL SERVICES"},
      {"9987", "MAINTENANCE SERVICES"},
      {"998719", "OTHER MAINTENANCE SERVICES"}
    ]

    strings =
      (hsn_rows ++ sac_rows)
      |> Enum.flat_map(fn {code, description} -> [code, description] end)
      |> Enum.uniq()

    indexes = strings |> Enum.with_index() |> Map.new()

    files = [
      {~c"xl/sharedStrings.xml", shared_strings_xml(strings)},
      {~c"xl/worksheets/sheet1.xml", sheet_xml(hsn_rows, indexes)},
      {~c"xl/worksheets/sheet2.xml", sheet_xml(sac_rows, indexes)}
    ]

    {:ok, {_name, bytes}} = :zip.create(~c"hsn.xlsx", files, [:memory])
    File.write!(path, bytes)
  end

  defp shared_strings_xml(strings) do
    body = Enum.map_join(strings, fn value -> "<si><t>#{value}</t></si>" end)

    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" <>
      "<sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">" <>
      body <> "</sst>"
  end

  defp sheet_xml(rows, indexes) do
    body =
      rows
      |> Enum.with_index(1)
      |> Enum.map_join(fn {{code, description}, row} ->
        "<row r=\"#{row}\">" <>
          cell("A", row, indexes[code]) <>
          cell("B", row, indexes[description]) <>
          "</row>"
      end)

    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" <>
      "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">" <>
      "<sheetData>#{body}</sheetData></worksheet>"
  end

  defp cell(column, row, index),
    do: "<c r=\"#{column}#{row}\" t=\"s\"><v>#{index}</v></c>"
end
