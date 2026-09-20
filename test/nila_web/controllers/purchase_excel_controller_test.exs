defmodule NilaWeb.PurchaseExcelControllerTest do
  use NilaWeb.ConnCase, async: true
  alias Nila.Gst.Purchase.Excel
  alias Nila.Gst.Sales.Excel.Workbook

  test "download has a blank entry sheet and an example the importer understands", %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Nila.Clients.create_client(%{
        org_id: org.id,
        name: "Template QA",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    downloaded = conn |> log_in_user(user) |> get("/gst/purchases-template.xlsx")
    bytes = response(downloaded, 200)

    assert hd(get_resp_header(downloaded, "content-disposition")) =~
             "Nila-purchases-template.xlsx"

    assert {:ok, workbook} = Workbook.read(bytes)
    blank = Enum.find(workbook.sheets, &(&1.name == "Purchases"))
    example = Enum.find(workbook.sheets, &(&1.name == "Example"))
    assert blank && example
    blank_mapping = Excel.suggest(blank)
    assert Enum.all?(Excel.required_fields(), &Map.has_key?(blank_mapping.mapping, &1))
    assert Enum.all?(blank.rows, &(&1.row <= blank_mapping.header))
    suggestion = Excel.suggest(example)

    assert {:ok, preview} =
             Excel.preview(
               workbook,
               example.name,
               suggestion.header,
               suggestion.mapping,
               [],
               client,
               "2026-09"
             )

    assert preview.errors == []
    assert length(preview.invoices) == 2
    assert preview.totals["taxable_value"] == 4000
    assert preview.totals["cgst_amount"] == 90
    assert preview.totals["sgst_amount"] == 90
    assert preview.totals["igst_amount"] == 410
  end

  test "template download requires login", %{conn: conn} do
    assert conn |> get("/gst/purchases-template.xlsx") |> redirected_to() == "/users/log_in"
  end
end
