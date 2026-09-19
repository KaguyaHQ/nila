defmodule Nila.Gst.Sales.ExcelTest do
  use Nila.DataCase, async: true
  alias Nila.Gst.Sales.Excel
  alias Nila.Gst.Sales.Excel.{Import, Workbook}
  alias Nila.Gst.Intake.{Dumps, DumpWorker}
  import Nila.AccountsFixtures

  setup do
    %{org: org, user: user} = user_with_org_fixture()

    {:ok, client} =
      Nila.Clients.create_client(%{
        org_id: org.id,
        name: "Excel test",
        gstin: "33AEWPH4158J1Z3",
        type: "company"
      })

    %{client: client, scope: Nila.Accounts.Scope.for_user(user), org: org}
  end

  defp read(name) do
    bytes = File.read!("test/fixtures/sales_excel/#{name}.xlsx")
    {:ok, workbook} = Workbook.read(bytes)
    sheet = hd(workbook.sheets)
    suggestion = Excel.suggest(sheet)
    {bytes, workbook, sheet, suggestion}
  end

  defp preview(name, client) do
    {_, workbook, sheet, suggestion} = read(name)

    Excel.preview(
      workbook,
      sheet.name,
      suggestion.header,
      suggestion.mapping,
      Excel.subtotal_rows(sheet, suggestion.header),
      client,
      "2026-08"
    )
  end

  test "different layouts produce the same invoice facts and exact money totals", %{
    client: client
  } do
    results =
      for name <- ~w(standard reordered subtotals) do
        assert {:ok, result} = preview(name, client)
        assert result.errors == []
        assert length(result.invoices) == 2
        assert result.row_count == 3

        assert result.totals == %{
                 "taxable_value" => 4000.0,
                 "cgst_amount" => 90.0,
                 "sgst_amount" => 90.0,
                 "igst_amount" => 410.0
               }

        [first, second] = result.invoices
        assert first["invoice_date"] == ~D[2026-08-05]
        assert second["printed_grand_total"] == 3410
        assert length(second["line_items"]) == 2
        Enum.map(result.invoices, &Map.drop(&1, ~w(source_sheet source_rows)))
      end

    assert length(Enum.uniq(results)) == 1
  end

  test "unexcluded subtotal is an error, never a silently imported invoice", %{client: client} do
    {_, workbook, sheet, suggestion} = read("subtotals")

    {:ok, result} =
      Excel.preview(
        workbook,
        sheet.name,
        suggestion.header,
        suggestion.mapping,
        [],
        client,
        "2026-08"
      )

    assert Enum.any?(result.errors, &(&1.row == 10))
  end

  test "manual mappings, ambiguous headers and duplicate mappings", %{client: client} do
    {_, workbook, sheet, suggestion} = read("standard")
    renamed = put_in(sheet, [:rows, Access.at(0), :cells, "A"], "Our reference")
    refute Map.has_key?(Excel.suggest(renamed).mapping, "invoice_number")
    workbook = %{workbook | sheets: [renamed]}

    assert {:ok, %{errors: []}} =
             Excel.preview(workbook, sheet.name, 1, suggestion.mapping, [], client, "2026-08")

    assert {:error, _} =
             Excel.preview(
               workbook,
               sheet.name,
               1,
               Map.put(suggestion.mapping, "buyer_name", "A"),
               [],
               client,
               "2026-08"
             )
  end

  test "invalid cells and conflicting invoice details block the whole import", %{client: client} do
    {_, workbook, sheet, suggestion} = read("standard")

    sheet =
      sheet
      |> put_in([:rows, Access.at(1), :cells, "H"], :formula)
      |> put_in([:rows, Access.at(3), :cells, "C"], "Different customer")

    {:ok, result} =
      Excel.preview(
        %{workbook | sheets: [sheet]},
        sheet.name,
        1,
        suggestion.mapping,
        [],
        client,
        "2026-08"
      )

    assert Enum.any?(result.errors, &String.contains?(&1.message, "formulas"))
    assert Enum.any?(result.errors, &String.contains?(&1.message, "conflicting"))

    {:ok, outside} =
      Excel.preview(workbook, sheet.name, 1, suggestion.mapping, [], client, "2026-07")

    assert Enum.any?(outside.errors, &String.contains?(&1.message, "outside"))
  end

  test "confirmed import preserves evidence, derives workings and rejects duplicates", %{
    scope: scope,
    client: client,
    org: org
  } do
    {bytes, _, sheet, suggestion} = read("standard")
    selection = Map.merge(suggestion, %{sheet: sheet.name, excluded: []})
    assert {:ok, dump} = Import.save(scope, client.id, "2026-08", bytes, "sales.xlsx", selection)
    assert dump.status == "received"
    assert length(dump.invoices) == 2
    assert hd(dump.invoices)["source_rows"] == [2]
    assert {:ok, ^bytes} = Nila.Storage.get(hd(dump.file_keys))
    assert :ok = DumpWorker.perform(%Oban.Job{args: %{"dump_id" => dump.id}, attempt: 1})
    assert {:ok, %{status: "extracted"}} = Dumps.fetch(org.id, dump.id)
    assert {:ok, month} = Nila.Gst.Sales.Months.get_by_period(org.id, client.id, "2026-08")
    assert length(month.invoices) == 2
    assert hd(month.invoices)["source_sheet"] == "Sales"

    assert {:error, message} =
             Import.save(scope, client.id, "2026-08", bytes, "again.xlsx", selection)

    assert message =~ "already"
    {changed_bytes, _, changed_sheet, changed_suggestion} = read("reordered")

    assert {:error, message} =
             Import.save(
               scope,
               client.id,
               "2026-08",
               changed_bytes,
               "renamed.xlsx",
               Map.merge(changed_suggestion, %{sheet: changed_sheet.name, excluded: []})
             )

    assert message =~ "same number and date"
  end

  test "viewer and cross-tenant imports do not write", %{scope: scope, client: client} do
    {bytes, _, sheet, suggestion} = read("standard")
    selection = Map.merge(suggestion, %{sheet: sheet.name, excluded: []})
    viewer = %{scope | membership: %{scope.membership | role: "viewer"}}
    assert {:error, _} = Import.save(viewer, client.id, "2026-08", bytes, "sales.xlsx", selection)
    %{user: foreign} = user_with_org_fixture()

    assert {:error, :not_found} =
             Import.save(
               Nila.Accounts.Scope.for_user(foreign),
               client.id,
               "2026-08",
               bytes,
               "sales.xlsx",
               selection
             )
  end

  test "mapped quantities reach saved invoices, B2C HSN and Excel workings", %{
    scope: scope,
    client: client,
    org: org
  } do
    bytes = quantity_workbook()
    {:ok, workbook} = Workbook.read(bytes)
    sheet = hd(workbook.sheets)
    suggestion = Excel.suggest(sheet)
    assert suggestion.mapping["quantity"] == "O"
    assert suggestion.mapping["uom"] == "P"
    selection = Map.merge(suggestion, %{sheet: sheet.name, excluded: []})

    assert {:ok, preview} =
             Excel.preview(
               workbook,
               sheet.name,
               suggestion.header,
               suggestion.mapping,
               [],
               client,
               "2026-08"
             )

    assert preview.errors == []
    assert {:ok, dump} = Import.save(scope, client.id, "2026-08", bytes, "qty.xlsx", selection)
    assert :ok = DumpWorker.perform(%Oban.Job{args: %{"dump_id" => dump.id}, attempt: 1})
    assert {:ok, month} = Nila.Gst.Sales.Months.get_by_period(org.id, client.id, "2026-08")

    for invoice <- month.invoices, line <- invoice["line_items"] do
      assert line["quantity"] == 10
      assert line["uom"] == "NOS"
    end

    derived =
      Nila.Gst.Sales.Gstr1.derive(
        month.invoices,
        Nila.Gst.Sales.Gstr1.production_header(client.gstin, "2026-08")
      )

    assert [%{"qty" => 10.0, "uqc" => "NOS"}] = get_in(derived, ["hsn", "hsn_b2c"])

    projection = %{
      invoices: month.invoices,
      active_invoices: month.invoices,
      issues: [],
      derived: derived
    }

    assert {:ok, output} = Nila.Gst.Sales.Workings.Xlsx.build(projection, client, "2026-08")
    assert {:ok, exported} = Workbook.read(output)
    hsn = Enum.find(exported.sheets, &(&1.name == "HSN"))
    assert hsn

    for row_number <- 5..7 do
      row = Enum.find(hsn.rows, &(&1.row == row_number))
      assert row.cells["D"] == "NOS"
      assert {10.0, ""} = Float.parse(row.cells["E"])
    end
  end

  test "invalid mapped quantities and units block import while missing quantities stay optional",
       %{
         client: client
       } do
    {:ok, workbook} = Workbook.read(quantity_workbook())
    sheet = hd(workbook.sheets)
    suggestion = Excel.suggest(sheet)

    for {column, value, message} <- [
          {"O", "ten", "Quantity per row is not a valid number"},
          {"O", "-10", "Quantity per row is negative"},
          {"O", :formula, "Quantity per row: replace formulas"},
          {"P", "123", "Unit of measure must contain"},
          {"P", :invalid_cell, "Unit of measure: replace formulas"}
        ] do
      changed = put_in(sheet, [:rows, Access.at(1), :cells, column], value)

      assert {:ok, result} =
               Excel.preview(
                 %{workbook | sheets: [changed]},
                 sheet.name,
                 1,
                 suggestion.mapping,
                 [],
                 client,
                 "2026-08"
               )

      assert Enum.any?(result.errors, &(&1.row == 2 and String.contains?(&1.message, message)))
    end

    assert {:ok, result} = preview("standard", client)
    assert result.errors == []
    assert hd(hd(result.invoices)["line_items"])["quantity"] == nil
    assert hd(hd(result.invoices)["line_items"])["uom"] == nil
  end

  defp quantity_workbook do
    {bytes, _, _, _} = read("standard")
    {:ok, entries} = :zip.extract(bytes, [:memory])

    entries =
      Enum.map(entries, fn {name, xml} ->
        if to_string(name) == "xl/worksheets/sheet1.xml" do
          xml = String.replace(xml, "998719", "8471")

          xml =
            Regex.replace(~r/<x:row r="([1-4])"[^>]*>.*?<\/x:row>/s, xml, fn row, index ->
              {qty, unit} = if index == "1", do: {"Qty", "UOM"}, else: {"10", "NOS"}

              cells =
                ~s(<x:c r="O#{index}" t="str"><x:v>#{qty}</x:v></x:c>) <>
                  ~s(<x:c r="P#{index}" t="str"><x:v>#{unit}</x:v></x:c>)

              String.replace(row, "</x:row>", cells <> "</x:row>")
            end)

          {name, xml}
        else
          {name, xml}
        end
      end)

    {:ok, {_, output}} = :zip.create(~c"quantity.xlsx", entries, [:memory])
    output
  end

  test "rejects non-xlsx data and oversized archives" do
    assert {:error, :invalid_file} = Workbook.read("not a workbook")
    assert {:error, :too_large} = Workbook.read(:binary.copy("0", Workbook.max_bytes() + 1))
  end

  test "source total controls compare independently with included rows", %{client: client} do
    assert {:ok, result} = preview("subtotals", client)
    assert length(result.controls) == 4
    assert Enum.all?(result.controls, &(&1.difference == 0))
    {_, workbook, sheet, suggestion} = read("subtotals")

    {:ok, partial} =
      Excel.preview(
        workbook,
        sheet.name,
        suggestion.header,
        suggestion.mapping,
        [7, 10],
        client,
        "2026-08"
      )

    assert Enum.find(partial.controls, &(&1.label == "Taxable value per row")).difference == -1000
  end

  test "notes, negative amounts, zero-tax sales and duplicate rows stay blocked", %{
    client: client
  } do
    {_, workbook, sheet, suggestion} = read("standard")

    for {column, value} <- [{"H", "-1000"}, {"J", "0"}, {"O", "Credit note"}] do
      changed =
        sheet
        |> put_in([:rows, Access.at(0), :cells, "O"], "Document type")
        |> put_in([:rows, Access.at(1), :cells, column], value)

      changed =
        if column == "J",
          do: put_in(changed, [:rows, Access.at(1), :cells, "K"], "0"),
          else: changed

      mapping = Map.put(suggestion.mapping, "document_type", "O")

      {:ok, result} =
        Excel.preview(
          %{workbook | sheets: [changed]},
          sheet.name,
          1,
          mapping,
          [],
          client,
          "2026-08"
        )

      assert result.errors != []
    end

    duplicate = %{Enum.at(sheet.rows, 1) | row: 5}
    changed = %{sheet | rows: sheet.rows ++ [duplicate]}

    {:ok, result} =
      Excel.preview(
        %{workbook | sheets: [changed]},
        sheet.name,
        1,
        suggestion.mapping,
        [],
        client,
        "2026-08"
      )

    assert Enum.any?(result.errors, &String.contains?(&1.message, "identical rows"))
  end

  test "the 1904 date system produces the same invoice dates", %{client: client} do
    {_, workbook, sheet, suggestion} = read("standard")

    rows =
      Enum.map(sheet.rows, fn row ->
        if row.row == 1,
          do: row,
          else:
            update_in(row, [:cells, "B"], fn value ->
              {number, ""} = Float.parse(value)
              to_string(number - 1462)
            end)
      end)

    workbook = %{workbook | sheets: [%{sheet | rows: rows}], date1904?: true}

    {:ok, result} =
      Excel.preview(workbook, sheet.name, 1, suggestion.mapping, [], client, "2026-08")

    assert result.errors == []
    assert hd(result.invoices)["invoice_date"] == ~D[2026-08-05]
  end

  test "a missing GSTIN alone never turns an unknown customer into B2C", %{client: client} do
    {_, workbook, sheet, suggestion} = read("standard")

    {:ok, result} =
      Excel.preview(
        workbook,
        sheet.name,
        1,
        Map.delete(suggestion.mapping, "recipient_registration"),
        [],
        client,
        "2026-08"
      )

    assert hd(result.invoices)["recipient_registration"] == "unknown"
    assert Enum.at(result.invoices, 1)["recipient_registration"] == "registered"
  end

  test "XLSX formula cells and hostile XML are never evaluated" do
    {bytes, _, _, _} = read("standard")

    rewrite = fn source, path, transform ->
      {:ok, files} = :zip.extract(source, [:memory])

      files =
        Enum.map(files, fn {name, data} ->
          {name, if(to_string(name) == path, do: transform.(data), else: data)}
        end)

      {:ok, {_, result}} = :zip.create(~c"test.xlsx", files, [:memory])
      result
    end

    malicious =
      rewrite.(
        bytes,
        "xl/workbook.xml",
        &("<!DOCTYPE foo [<!ENTITY x SYSTEM 'file:///secret'>]>" <> &1)
      )

    assert {:error, :invalid_file} = Workbook.read(malicious)

    formula =
      rewrite.(
        bytes,
        "xl/worksheets/sheet1.xml",
        &String.replace(&1, "<x:v>1000</x:v>", "<x:f>500+500</x:f><x:v>1000</x:v>")
      )

    assert {:ok, workbook} = Workbook.read(formula)
    assert Enum.any?(hd(workbook.sheets).rows, &(:formula in Map.values(&1.cells)))
  end
end
