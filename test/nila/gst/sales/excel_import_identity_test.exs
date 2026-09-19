defmodule Nila.Gst.Sales.ExcelImportIdentityTest do
  use Nila.DataCase, async: true

  import Nila.AccountsFixtures

  alias Nila.Gst.Sales.Batch
  alias Nila.Gst.Sales.Excel
  alias Nila.Gst.Sales.Excel.{Import, Workbook}
  alias Nila.Gst.Sales.Invoice.{Corrections, Removals}

  setup do
    %{org: org, user: user} = user_with_org_fixture()

    {:ok, client} =
      Nila.Clients.create_client(%{
        org_id: org.id,
        name: "Excel identities",
        gstin: "33AEWPH4158J1Z3",
        type: "company"
      })

    bytes = File.read!("test/fixtures/sales_excel/standard.xlsx")
    {:ok, workbook} = Workbook.read(bytes)
    sheet = hd(workbook.sheets)
    selection = Map.merge(Excel.suggest(sheet), %{sheet: sheet.name, excluded: [3, 4]})
    scope = Nila.Accounts.Scope.for_user(user)

    assert {:ok, dump} = Import.save(scope, client.id, "2026-08", bytes, "sales.xlsx", selection)
    dump = Repo.reload!(dump)
    assert [invoice] = dump.invoices

    %{
      org: org,
      user: user,
      client: client,
      scope: scope,
      bytes: bytes,
      selection: selection,
      dump: dump,
      source_id: invoice["id"]
    }
  end

  test "corrected numbers release the old identity and block the new identity", c do
    assert {:ok, _} =
             Corrections.save(
               c.org.id,
               c.client.id,
               Batch.ref([c.dump]),
               c.source_id,
               %{"invoice_number" => "CORRECTED-001"},
               c.user.id
             )

    corrected_bytes = rewrite(c.bytes, "DEMO-001", "CORRECTED-001")
    assert {:error, message} = save(c, corrected_bytes)
    assert message =~ "same number and date"

    replacement_bytes = rewrite(c.bytes, "Repair service", "Replacement service")
    assert {:ok, replacement} = save(c, replacement_bytes)
    assert [invoice] = replacement.invoices
    assert invoice["invoice_number"] == "DEMO-001"
    assert invoice["id"] != c.source_id
    assert hd(Repo.reload!(c.dump).invoices)["invoice_number"] == "DEMO-001"
  end

  test "a removed source allows its replacement from different workbook bytes", c do
    assert {:ok, _} =
             Removals.remove(
               c.org.id,
               c.client.id,
               Batch.ref([c.dump]),
               c.source_id,
               c.user.id
             )

    replacement_bytes = rewrite(c.bytes, "Repair service", "Replacement service")
    refute replacement_bytes == c.bytes
    assert {:ok, replacement} = save(c, replacement_bytes)
    assert hd(replacement.invoices)["invoice_number"] == "DEMO-001"
    assert hd(replacement.invoices)["id"] != c.source_id
    assert Repo.reload!(c.dump).invoices == c.dump.invoices
  end

  test "a pending import still blocks the same invoice in different workbook bytes", c do
    assert c.dump.status == "received"
    replacement_bytes = rewrite(c.bytes, "Repair service", "Replacement service")
    assert {:error, message} = save(c, replacement_bytes)
    assert message =~ "same number and date"
  end

  defp save(c, bytes),
    do: Import.save(c.scope, c.client.id, "2026-08", bytes, "replacement.xlsx", c.selection)

  defp rewrite(bytes, original, replacement) do
    {:ok, files} = :zip.extract(bytes, [:memory])

    files =
      Enum.map(files, fn
        {~c"xl/worksheets/sheet1.xml" = name, xml} ->
          {name, String.replace(xml, original, replacement)}

        file ->
          file
      end)

    {:ok, {_, result}} = :zip.create(~c"replacement.xlsx", files, [:memory])
    result
  end
end
