defmodule Nila.Gst.Sales.KpnRegisterTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Sales.Excel.KpnRegister

  @seller "33AEGPN1094P1Z4"
  @header %{
    "A" => "Date",
    "B" => "Particulars",
    "C" => "Voucher Type",
    "D" => "Voucher No.",
    "E" => "Voucher Ref. No.",
    "F" => "GSTIN/UIN",
    "G" => "Gross Total",
    "H" => "GST SALES @ 18 % (9403)",
    "I" => "Output C Gst@9%",
    "J" => "Output S Gst@9%",
    "K" => "Transport",
    "L" => "Round of",
    "M" => "IGST SALES @ 18 % (9403)",
    "N" => "Output Igst Tax @ 18%"
  }

  defp row(n, cells), do: %{row: n, cells: cells}

  defp workbook(rows) do
    %{
      sheets: [
        %{
          name: "Sales Register",
          hidden?: false,
          rows: [
            row(5, %{"A" => "GSTIN/UIN : #{@seller}"}),
            row(10, %{"A" => "Sales Register"}),
            row(11, %{"A" => "1-Aug-26 to 31-Aug-26"}),
            row(12, @header)
            | rows
          ]
        }
      ]
    }
  end

  test "reads printed local and interstate tax; keeps HSN without inventing units" do
    cash =
      row(13, %{
        "A" => "46235",
        "B" => "CASH SALES",
        "C" => "Sales",
        "D" => "216",
        "G" => "590",
        "H" => "500",
        "I" => "45",
        "J" => "45"
      })

    interstate =
      row(14, %{
        "A" => "2026-08-24T00:00:00",
        "B" => "Vishnu cars Pvt. Ltd - Andhra Pradesh",
        "C" => "Sales",
        "D" => "239",
        "F" => "37AABCV9886D1ZT",
        "G" => "7979.5",
        "M" => "6550",
        "N" => "1179",
        "K" => "250",
        "L" => "0.50"
      })

    total = row(15, %{"B" => "Grand Total", "G" => "8319"})
    source = workbook([cash, interstate, total])

    assert KpnRegister.matches?(source)

    assert {:ok, %{"format" => "kpn_register", "rows" => [], "invoices" => invoices}} =
             KpnRegister.parse(source, %{gstin: @seller}, "2026-08")

    assert [cash_invoice, interstate_invoice] = invoices
    assert cash_invoice["recipient_registration"] == "unregistered"
    assert cash_invoice["invoice_date"] == ~D[2026-08-01]
    assert cash_invoice["place_of_supply"] == "33"
    assert cash_invoice["place_of_supply_basis"] == "CGST/SGST; seller state"
    assert cash_invoice["source_rows"] == [13]
    assert cash_invoice["return_report_section"] == "KPN"
    assert [cash_line] = cash_invoice["line_items"]
    assert cash_line["hsn_sac"] == "9403"
    assert cash_line["quantity"] == nil
    assert cash_line["uom"] == nil
    assert cash_line["cgst_amount"] == 45.0
    assert cash_line["sgst_amount"] == 45.0
    assert cash_line["printed_taxable_value"] == 500.0

    assert interstate_invoice["recipient_registration"] == "registered"
    assert interstate_invoice["place_of_supply"] == "37"
    assert interstate_invoice["place_of_supply_basis"] == "IGST; buyer GSTIN state"
    assert interstate_invoice["source_transport_amount"] == 250.0
    assert interstate_invoice["source_rounding_amount"] == 0.5
    assert interstate_invoice["printed_additional_charges"] == 250.0
    assert interstate_invoice["printed_rounding_adjustment"] == 0.5
    assert interstate_invoice["source_cells"]["M"] == "6550"
    assert [interstate_line] = interstate_invoice["line_items"]
    assert interstate_line["igst_amount"] == 1179.0
    assert interstate_line["printed_taxable_value"] == 6550.0
  end

  test "rejects a tax pattern that conflicts with the buyer's state" do
    bad =
      row(13, %{
        "A" => "2026-08-01T00:00:00",
        "B" => "Buyer",
        "C" => "Sales",
        "D" => "216",
        "F" => "37AABCV9886D1ZT",
        "G" => "590",
        "H" => "500",
        "I" => "45",
        "J" => "45"
      })

    assert {:error, message} = KpnRegister.parse(workbook([bad]), %{gstin: @seller}, "2026-08")
    assert message =~ "row 13"
    assert message =~ "conflicts with buyer GSTIN state"
  end

  test "rejects another client's GSTIN" do
    assert {:error, message} =
             KpnRegister.parse(workbook([]), %{gstin: "33AAACR7926B1ZP"}, "2026-08")

    assert message =~ "does not match this client"
  end
end
