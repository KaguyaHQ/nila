defmodule Nila.Gst.Sales.UltinoRegisterTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Sales.Excel.{ReturnReport, UltinoRegister}

  @client %{gstin: "33AABCU1234F1Z1"}

  defp row(number, cells), do: %{row: number, cells: cells}

  defp workbook(invoice_rows) do
    %{
      sheets: [
        %{
          name: "Sheet1",
          hidden?: false,
          rows: [
            row(1, %{"A" => "ULTINO TECH CNC"}),
            row(3, %{"A" => "GST Sales Details From 01-Aug-2026 To 31-Aug-2026"}),
            row(6, %{
              "B" => "Inv.No",
              "D" => "Inv.Date",
              "H" => "Party GSTIN No",
              "J" => "Taxable Value"
            })
            | invoice_rows
          ]
        }
      ]
    }
  end

  defp invoice(cells \\ %{}) do
    Map.merge(
      %{
        "B" => "174",
        "D" => "2026-08-07T13:29:00",
        "E" => "Buyer",
        "H" => "33AABCI3906K1ZQ",
        "J" => "16200",
        "L" => "9",
        "O" => "1458",
        "P" => "9",
        "S" => "1458",
        "U" => "0",
        "W" => "0",
        "AC" => "19116"
      },
      cells
    )
  end

  test "uses printed tax amounts and skips the separate grand total" do
    interstate =
      invoice(%{
        "B" => "175",
        "H" => "29AAACG6643E1ZN",
        "J" => "65560",
        "L" => "0",
        "O" => "0",
        "P" => "0",
        "S" => "0",
        "U" => "18",
        "W" => "11800.8",
        "AC" => "77360.8"
      })

    workbook =
      workbook([
        row(10, invoice()),
        row(18, interstate),
        row(80, %{"F" => "Total", "J" => "81760", "AA" => "96476.8"})
      ])

    assert UltinoRegister.matches?(workbook)
    assert {:ok, report} = UltinoRegister.parse(workbook, @client, "2026-08")
    assert length(report["rows"]) == 2

    assert [%{"return_report_section" => "B2B"} = local, interstate_invoice] =
             ReturnReport.invoices(report, @client)

    assert local["invoice_number"] == "174"
    assert local["place_of_supply"] == "33"
    assert local["line_items"] |> hd() |> Map.fetch!("cgst_amount") == 1458.0

    assert local["return_report_values"] |> hd() |> Map.fetch!("pos_basis") ==
             "recipient_gstin_tax_pattern"

    assert interstate_invoice["invoice_number"] == "175"
    assert interstate_invoice["place_of_supply"] == "29"
    assert interstate_invoice["line_items"] |> hd() |> Map.fetch!("igst_amount") == 11800.8
  end

  test "rejects a row where the derived state and tax pattern disagree" do
    workbook = workbook([row(10, invoice(%{"H" => "29AAACG6643E1ZN"}))])
    assert {:error, message} = UltinoRegister.parse(workbook, @client, "2026-08")
    assert message =~ "conflicts with the recipient's state"
  end

  test "rejects a different GST month" do
    workbook = workbook([row(10, invoice())])
    assert {:error, message} = UltinoRegister.parse(workbook, @client, "2026-07")
    assert message =~ "Report period does not match"
  end
end
