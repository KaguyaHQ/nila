defmodule Nila.Clients.ImportTest do
  use Nila.DataCase, async: true
  import Nila.AccountsFixtures
  alias Nila.Clients.{Import, ImportXlsx}
  alias Nila.{Clients, Repo}

  setup do
    %{user: user, org: org} = user_with_org_fixture()
    %{scope: Nila.Accounts.Scope.for_user(user), org: org}
  end

  defp workbook(rows) do
    sheet =
      Enum.with_index([["Client name", "GSTIN", "GST username"] | rows])
      |> Enum.reduce(XlsxWriter.new_sheet("Clients"), fn {cells, row}, sheet ->
        Enum.with_index(cells)
        |> Enum.reduce(sheet, fn {cell, col}, sheet -> XlsxWriter.write(sheet, row, col, cell) end)
      end)

    {:ok, bytes} = XlsxWriter.generate([sheet])
    bytes
  end

  test "preview normalizes identities, permits blank GSTIN, and writes only on confirmation", %{
    scope: scope,
    org: org
  } do
    bytes = workbook([["  Breeze Tech  ", "33aewph4158j1z3"], ["Unregistered client", ""]])
    assert {:ok, preview} = Import.preview(scope, bytes)

    assert [
             %{name: "Breeze Tech", gstin: "33AEWPH4158J1Z3", row: 2, status: :ready},
             %{gstin: nil, status: :ready}
           ] = preview.rows

    assert Clients.list_clients(org.id) == []
    assert {:ok, results} = Import.save(scope, preview.rows)
    assert Enum.all?(results, &(&1.status == :added))
    assert length(Clients.list_clients(org.id)) == 2
    assert {:ok, again} = Import.preview(scope, bytes)
    assert Enum.all?(again.rows, &(&1.status == :skip))
  end

  test "bad checksums, missing names and duplicates are visible and excluded", %{
    scope: scope,
    org: org
  } do
    {:ok, _} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Existing",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    bytes =
      workbook([
        ["New", ""],
        ["Bad GSTIN", "33AEWPH4158J1Z0"],
        ["", "33CPWPV2650A1ZQ"],
        ["Different name", "33AEWPH4158J1Z3"],
        [" existing ", ""],
        ["Repeated", ""],
        ["REPEATED", ""]
      ])

    {:ok, preview} = Import.preview(scope, bytes)

    assert Enum.map(preview.rows, & &1.status) == [
             :ready,
             :invalid,
             :invalid,
             :skip,
             :skip,
             :invalid,
             :invalid
           ]

    assert {:ok, results} = Import.save(scope, preview.rows)
    assert Enum.count(results, &(&1.status == :added)) == 1
    assert Enum.map(Clients.list_clients(org.id), & &1.name) == ["Existing", "New"]
  end

  test "another firm's GSTIN is not a duplicate; save rechecks new conflicts", %{
    scope: scope,
    org: org
  } do
    %{org: other} = user_with_org_fixture()

    {:ok, _} =
      Clients.create_client(%{
        org_id: other.id,
        name: "Other",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    {:ok, preview} = Import.preview(scope, workbook([["Breeze", "33AEWPH4158J1Z3"]]))
    assert hd(preview.rows).status == :ready

    {:ok, _} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Added meanwhile",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    assert {:ok, [%{status: :skip}]} = Import.save(scope, preview.rows)
    assert length(Clients.list_clients(org.id)) == 1
  end

  test "viewers cannot preview or save", %{scope: scope} do
    viewer = %{scope | membership: %{scope.membership | role: "viewer"}}
    assert {:error, :forbidden} = Import.preview(viewer, workbook([["New", ""]]))
    assert {:error, :forbidden} = Import.save(viewer, [])
  end

  test "username requires a GSTIN and fits the portal length limit", %{scope: scope} do
    assert {:ok, %{rows: rows}} =
             Import.preview(
               scope,
               workbook([
                 ["Missing GSTIN", "", "gst_user"],
                 ["Long username", "33AEWPH4158J1Z3", String.duplicate("a", 101)]
               ])
             )

    assert [
             %{status: :invalid, message: "Add a GSTIN for this GST username."},
             %{status: :invalid, message: "GST username is too long (maximum 100 characters)."}
           ] = rows
  end

  test "formulas are flagged rather than trusting their cached results", %{scope: scope} do
    sheet =
      XlsxWriter.new_sheet("Clients")
      |> XlsxWriter.write(0, 0, "Client name")
      |> XlsxWriter.write(0, 1, "GSTIN")
      |> XlsxWriter.write(0, 2, "GST username")
      |> XlsxWriter.write_formula(1, 0, "=1+1")

    {:ok, bytes} = XlsxWriter.generate([sheet])
    assert {:ok, %{rows: [%{status: :invalid, name: :formula}]}} = Import.preview(scope, bytes)
  end

  test "rejects corrupt files, ambiguous sheets, excessive rows, missing headings and DTDs" do
    assert {:error, :invalid_file} = ImportXlsx.read("not a zip")

    {:ok, sheets} =
      XlsxWriter.generate([XlsxWriter.new_sheet("One"), XlsxWriter.new_sheet("Two")])

    assert {:error, :multiple_sheets} = ImportXlsx.read(sheets)

    assert {:error, :too_many_rows} =
             ImportXlsx.read(workbook(for n <- 1..1001, do: ["Client #{n}", ""]))

    {:ok, empty} = Import.template()
    assert {:error, :empty_file} = ImportXlsx.read(empty)

    {:ok, headerless} =
      XlsxWriter.generate([
        XlsxWriter.new_sheet("Clients") |> XlsxWriter.write(0, 0, "Something else")
      ])

    assert {:error, :headers} = ImportXlsx.read(headerless)
    {:ok, entries} = :zip.extract(workbook([["Name", ""]]), [:memory])

    entries =
      Enum.map(entries, fn
        {~c"xl/workbook.xml", xml} ->
          {~c"xl/workbook.xml", "<!DOCTYPE x [<!ENTITY x SYSTEM 'file:///private'>]>" <> xml}

        other ->
          other
      end)

    {:ok, {_, malicious}} = :zip.create(~c"bad.xlsx", entries, [:memory])
    assert {:error, :invalid_file} = ImportXlsx.read(malicious)
  end

  test "reads sparse inline-string cells and preserves Unicode and Excel row numbers" do
    {:ok, entries} = :zip.extract(workbook([["Name", ""]]), [:memory])

    sheet = """
    <?xml version="1.0" encoding="UTF-8"?>
    <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
      <row r="1"><c r="B1" t="inlineStr"><is><t>Client name</t></is></c><c r="D1" t="inlineStr"><is><t>GSTIN</t></is></c><c r="F1" t="inlineStr"><is><t>GST username</t></is></c></row>
      <row r="5"><c r="B5" t="inlineStr"><is><t>தமிழ் &amp; Co</t></is></c></row>
    </sheetData></worksheet>
    """

    entries =
      Enum.map(entries, fn
        {~c"xl/worksheets/sheet1.xml", _} -> {~c"xl/worksheets/sheet1.xml", sheet}
        other -> other
      end)

    {:ok, {_, bytes}} = :zip.create(~c"inline.xlsx", entries, [:memory])
    assert {:ok, %{rows: [%{row: 5, name: "தமிழ் & Co", gstin: ""}]}} = ImportXlsx.read(bytes)
  end

  test "skipped rows do not become newly approved if an existing client disappears", %{
    scope: scope,
    org: org
  } do
    {:ok, existing} = Clients.create_client(%{org_id: org.id, name: "Existing", type: "company"})
    {:ok, preview} = Import.preview(scope, workbook([["Existing", ""], ["Approved", ""]]))
    Repo.delete!(existing)
    {:ok, rows} = Import.save(scope, preview.rows)
    assert Enum.map(rows, & &1.status) == [:skip, :added]
  end
end
