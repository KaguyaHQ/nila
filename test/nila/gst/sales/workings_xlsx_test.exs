defmodule Nila.Gst.Sales.WorkingsXlsxTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Sales.{Gstr1, WorkingsXlsx}

  test "builds the canonical six-sheet workbook and keeps tax and HSN grains separate" do
    invoice = mixed_rate_invoice()

    projection = %{
      invoices: [invoice],
      active_invoices: [invoice],
      issues: [],
      derived: Gstr1.derive([invoice], Gstr1.production_header(client().gstin, "2026-07"))
    }

    assert {:ok, workbook} =
             WorkingsXlsx.build(projection, client(), "2026-07", status: "Draft")

    assert <<"PK", _rest::binary>> = workbook

    files = entries(workbook)
    workbook_xml = Map.fetch!(files, "xl/workbook.xml")

    for name <- [
          "Summary",
          "Sales Register",
          "Tax Breakdown",
          "GSTR-1 Working",
          "HSN Working",
          "Exclusions &amp; Corrections"
        ] do
      assert workbook_xml =~ ~s(name="#{name}")
    end

    strings = Map.fetch!(files, "xl/sharedStrings.xml")
    assert strings =~ "Reported CGST"
    assert strings =~ "Expected CGST"
    assert strings =~ "Calculated CGST"
    assert strings =~ "Silver rod"

    tax_sheet = Map.fetch!(files, "xl/worksheets/sheet3.xml")
    assert tax_sheet =~ ~s(r="A5")
    assert tax_sheet =~ ~s(r="A6")
    refute tax_sheet =~ ~s(r="A7")
    assert tax_sheet =~ "ROUND(J5*I5/2,2)"
    assert tax_sheet =~ "ROUND(J6*I6/2,2)"

    hsn_sheet = Map.fetch!(files, "xl/worksheets/sheet5.xml")
    assert hsn_sheet =~ ~s(r="A5")
    assert hsn_sheet =~ ~s(r="A6")
    assert hsn_sheet =~ ~s(r="A7")
    assert hsn_sheet =~ ~s(r="A8")
    refute hsn_sheet =~ ~s(r="A9")
    assert hsn_sheet =~ "SUMIFS"
  end

  test "refuses to manufacture an empty working" do
    projection = %{invoices: [], active_invoices: [], issues: [], derived: %{}}

    assert {:error, :no_active_sales} =
             WorkingsXlsx.build(projection, client(), "2026-07")
  end

  test "HSN working preserves CGST and SGST treatment when explicit place of supply is absent" do
    invoice = mixed_rate_invoice() |> Map.put("place_of_supply", nil)

    projection = %{
      invoices: [invoice],
      active_invoices: [invoice],
      issues: [],
      derived: Gstr1.derive([invoice], Gstr1.production_header(client().gstin, "2026-07"))
    }

    {:ok, workbook} = WorkingsXlsx.build(projection, client(), "2026-07")
    files = entries(workbook)

    for row <- 5..8 do
      assert shared_cell(files, "xl/worksheets/sheet5.xml", "G#{row}") == "Intrastate"
    end

    assert shared_cell(files, "xl/worksheets/sheet3.xml", "H5") == "Intrastate"
  end

  defp shared_cell(files, sheet, address) do
    [_, index] =
      Regex.run(~r/<c r="#{address}"[^>]*t="s"[^>]*><v>(\d+)<\/v><\/c>/, Map.fetch!(files, sheet))

    strings =
      Regex.scan(
        ~r/<si><t(?: [^>]*)?>(.*?)<\/t><\/si>/s,
        Map.fetch!(files, "xl/sharedStrings.xml")
      )

    strings |> Enum.at(String.to_integer(index)) |> Enum.at(1)
  end

  defp mixed_rate_invoice do
    Gstr1.normalize_invoice(%{
      "data" => %{
        "document_type" => "invoice",
        "document_status" => "active",
        "supply_type" => "taxable",
        "recipient_registration" => "registered",
        "place_of_supply" => "33",
        "invoice_number" => "46/2026-27",
        "invoice_date" => "15.07.2026",
        "seller" => %{"name" => "Caltech Refrigeration", "gstin" => client().gstin},
        "buyer" => %{"name" => "Buyer One", "gstin" => "33AAVCS8021P1ZB"},
        "line_items" => [
          line("Silver rod", "71069290", 3_600, 3, 6),
          line("Copper fitting", "74121000", 1_500, 18, 3),
          line("Repair service", "998719", 17_000, 18, 5),
          line("Rubber hose", "40093200", 500, 18, 1)
        ],
        "printed_total_taxable" => 22_600,
        "printed_total_tax" => 3_528,
        "printed_grand_total" => 26_128
      }
    })
  end

  defp line(description, hsn, taxable, rate, quantity) do
    tax = taxable * rate / 200

    %{
      "description" => description,
      "hsn_description" => description,
      "hsn_sac" => hsn,
      "uom" => "Nos",
      "quantity" => quantity,
      "taxable_value" => taxable,
      "cgst_rate" => rate / 2,
      "cgst_amount" => tax,
      "sgst_rate" => rate / 2,
      "sgst_amount" => tax,
      "igst_rate" => 0,
      "igst_amount" => 0
    }
  end

  defp client do
    %{name: "Caltech Refrigeration", gstin: "33BPBPK1081A1ZO"}
  end

  defp entries(workbook) do
    {:ok, entries} = :zip.extract(workbook, [:memory])
    Map.new(entries, fn {path, bytes} -> {List.to_string(path), bytes} end)
  end
end
