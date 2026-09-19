defmodule Nila.Gst.Purchase.ExcelTest do
  use Nila.DataCase, async: true
  import Nila.AccountsFixtures
  alias Nila.Gst.Purchase.Excel
  alias Nila.Gst.Purchase.Excel.Import
  alias Nila.Gst.Sales.Excel.Workbook
  alias Nila.Gst.Intake.{Dumps, DumpWorker}

  setup do
    %{org: org, user: user} = user_with_org_fixture()

    {:ok, client} =
      Nila.Clients.create_client(%{
        org_id: org.id,
        name: "Purchase Excel",
        gstin: "33AEWPH4158J1Z3",
        type: "company"
      })

    %{client: client, org: org, scope: Nila.Accounts.Scope.for_user(user)}
  end

  defp sample do
    bytes = File.read!("test/fixtures/purchase_excel/standard.xlsx")
    {:ok, workbook} = Workbook.read(bytes)
    sheet = hd(workbook.sheets)
    mapping = Excel.suggest(sheet).mapping

    {bytes, workbook, sheet, mapping}
  end

  test "invoice summaries do not require rates and preserve paise and source rows", %{
    client: client
  } do
    {_, workbook, sheet, mapping} = sample()
    mapping = Map.delete(mapping, "gst_rate")
    assert {:ok, result} = Excel.preview(workbook, sheet.name, 1, mapping, [], client, "2026-09")
    assert result.errors == []
    assert length(result.invoices) == 2
    assert hd(result.invoices)["taxable_paise"] == 100_000
    assert hd(result.invoices)["tax_paise"] == %{"cgst" => 9000, "sgst" => 9000, "igst" => 0}
    assert hd(result.invoices)["source_rows"] == [2]
    assert List.last(result.invoices)["tax_paise"]["igst"] == 41000
  end

  test "same invoice number from different suppliers stays separate", %{client: client} do
    {_, workbook, sheet, mapping} = sample()
    first = Enum.at(sheet.rows, 1)
    other = %{first | row: 5, cells: Map.put(first.cells, "D", "29AABCU9603R1ZM")}
    sheet = %{sheet | rows: [hd(sheet.rows), first, other]}

    assert {:ok, result} =
             Excel.preview(
               %{workbook | sheets: [sheet]},
               sheet.name,
               1,
               mapping,
               [],
               client,
               "2026-08"
             )

    assert length(result.invoices) == 2
  end

  test "missing tax heads and unsupported documents block confirmation", %{client: client} do
    {_, workbook, sheet, mapping} = sample()

    for changed <- [
          Map.delete(mapping, "sgst_amount"),
          mapping |> Map.delete("vendor_name") |> Map.put("document_type", "C")
        ] do
      assert {:ok, result} =
               Excel.preview(workbook, sheet.name, 1, changed, [], client, "2026-08")

      assert result.errors != []
    end
  end

  test "save preserves workbook and derives purchase month without extraction", %{
    scope: scope,
    client: client,
    org: org
  } do
    {bytes, _, sheet, mapping} = sample()
    selection = %{sheet: sheet.name, header: 1, mapping: mapping, excluded: []}

    assert {:ok, dump} =
             Import.save(scope, client.id, "2026-08", bytes, "purchases.xlsx", selection)

    assert dump.kind == "purchase"
    assert {:ok, ^bytes} = Nila.Storage.get(hd(dump.file_keys))
    assert :ok = DumpWorker.perform(%Oban.Job{args: %{"dump_id" => dump.id}, attempt: 1})
    assert {:ok, %{status: "extracted"}} = Dumps.fetch(org.id, dump.id)
    assert {:ok, month} = Nila.Gst.Purchase.Months.get_by_period(org.id, client.id, "2026-08")
    assert length(month.register_rows) == 2

    assert {:error, reason} =
             Import.save(scope, client.id, "2026-08", bytes, "again.xlsx", selection)

    assert reason =~ "already"

    month |> Ecto.Changeset.change(filed_at: DateTime.utc_now()) |> Nila.Repo.update!()

    assert {:error, reason} =
             Import.save(scope, client.id, "2026-08", bytes, "again.xlsx", selection)

    assert reason =~ "signed or filed"
  end

  test "viewer and foreign tenant cannot import", %{scope: scope, client: client} do
    {bytes, _, sheet, mapping} = sample()
    selection = %{sheet: sheet.name, header: 1, mapping: mapping, excluded: []}
    viewer = %{scope | membership: %{scope.membership | role: "viewer"}}

    assert {:error, _} =
             Import.save(viewer, client.id, "2026-08", bytes, "purchases.xlsx", selection)

    %{user: foreign} = user_with_org_fixture()

    assert {:error, :not_found} =
             Import.save(
               Nila.Accounts.Scope.for_user(foreign),
               client.id,
               "2026-08",
               bytes,
               "purchases.xlsx",
               selection
             )
  end
end
