defmodule Nila.Gst.Filing.Gstr2bTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Filing.Gstr2b

  @gstin_a "33AAACS1234A1Z9"
  @fixtures Path.expand("../../../fixtures/purchase/breeze", __DIR__)

  defp portal_invoice(attrs \\ %{}) do
    Map.merge(
      %{
        "inum" => "INV-001",
        "dt" => "15-04-2025",
        "val" => 11800.0,
        "pos" => "33",
        "rev" => "N",
        "itcavl" => "Y",
        "items" => [
          %{
            "num" => 1,
            "rt" => 18,
            "txval" => 10000.0,
            "igst" => 0,
            "cgst" => 900.0,
            "sgst" => 900.0,
            "cess" => 0
          }
        ]
      },
      attrs
    )
  end

  defp portal_note(type, attrs \\ %{}) do
    Map.merge(
      %{
        "ntnum" => "CN-001",
        "typ" => type,
        "dt" => "16-04-2025",
        "val" => 2360.0,
        "txval" => 2000.0,
        "igst" => 360.0,
        "cgst" => 0,
        "sgst" => 0,
        "pos" => "29",
        "rev" => "N",
        "itcavl" => "Y",
        "imsStatus" => "N"
      },
      attrs
    )
  end

  defp portal_doc(invoices, notes \\ []) do
    %{
      "data" => %{
        "docdata" => %{
          "b2b" => [
            %{"ctin" => @gstin_a, "trdnm" => "Sharma Steels", "inv" => invoices}
          ],
          "cdnr" => [
            %{"ctin" => @gstin_a, "trdnm" => "Sharma Steels", "nt" => notes}
          ]
        }
      }
    }
  end

  test "normalizes a documented-shape invoice into paise maps" do
    assert {:ok, [inv]} = Gstr2b.parse(portal_doc([portal_invoice()]))

    assert inv["document_type"] == "invoice"
    assert inv["source_section"] == "b2b"
    assert inv["vendor_gstin"] == @gstin_a
    assert inv["vendor_name"] == "Sharma Steels"
    assert inv["invoice_number"] == "INV-001"
    assert inv["invoice_date"] == ~D[2025-04-15]
    assert inv["total_paise"] == 1_180_000
    assert inv["taxable_paise"] == 1_000_000
    assert inv["tax_paise"] == %{"cgst" => 90_000, "sgst" => 90_000, "igst" => 0}
    assert inv["itc_available"] == true
    assert inv["reverse_charge"] == false
    assert inv["pos"] == "33"
  end

  test "accepts a dump wrapped at docdata without the data envelope" do
    %{"data" => inner} = portal_doc([portal_invoice()])

    assert {:ok, [inv]} = Gstr2b.parse(inner)
    assert inv["invoice_number"] == "INV-001"
  end

  test "parses from a raw JSON binary" do
    json = Jason.encode!(portal_doc([portal_invoice()]))

    assert {:ok, [inv]} = Gstr2b.parse(json)
    assert inv["total_paise"] == 1_180_000
  end

  test "sums taxes across multiple items and converts float rupees to paise without drift" do
    invoice =
      portal_invoice(%{
        "val" => 335.3,
        "items" => [
          %{
            "num" => 1,
            "rt" => 18,
            "txval" => 100.1,
            "igst" => 18.02,
            "cgst" => 0,
            "sgst" => 0,
            "cess" => 0
          },
          %{
            "num" => 2,
            "rt" => 18,
            "txval" => 184.1,
            "igst" => 33.14,
            "cgst" => 0,
            "sgst" => 0,
            "cess" => 0
          }
        ]
      })

    assert {:ok, [inv]} = Gstr2b.parse(portal_doc([invoice]))
    assert inv["taxable_paise"] == 28_420
    assert inv["tax_paise"]["igst"] == 5_116
    assert inv["total_paise"] == 33_530
  end

  test "normalizes positive-valued portal credit and debit notes with their type" do
    notes = [portal_note("C"), portal_note("D", %{"ntnum" => "DN-001", "igst" => 180.0})]

    assert {:ok, [_invoice, credit, debit]} = Gstr2b.parse(portal_doc([portal_invoice()], notes))

    assert credit["document_type"] == "credit_note"
    assert credit["source_section"] == "cdnr"
    assert credit["invoice_number"] == "CN-001"
    assert credit["taxable_paise"] == 200_000
    assert credit["tax_paise"]["igst"] == 36_000
    assert credit["total_paise"] == 236_000
    assert credit["ims_status"] == "N"

    assert debit["document_type"] == "debit_note"
    assert debit["invoice_number"] == "DN-001"
    assert debit["tax_paise"]["igst"] == 18_000
  end

  test "parses CDNR from real portal fixtures" do
    december =
      @fixtures
      |> Path.join("2025-12/returns_R2B_33AEWPH4158J1Z3_122025.json")
      |> File.read!()
      |> Gstr2b.parse()
      |> elem(1)

    april =
      @fixtures
      |> Path.join("2026-04/returns_R2B_33AEWPH4158J1Z3_042026.json")
      |> File.read!()
      |> Gstr2b.parse()
      |> elem(1)

    assert [%{"document_type" => "credit_note", "invoice_number" => "13"}] =
             Enum.filter(december, &(&1["source_section"] == "cdnr"))

    assert [
             %{"document_type" => "debit_note", "invoice_number" => "PY3613400001"},
             %{"document_type" => "debit_note", "invoice_number" => "PY3613400002"}
           ] = Enum.filter(april, &(&1["source_section"] == "cdnr"))
  end

  test "surfaces reverse charge and ITC-unavailable lines with the portal reason" do
    invoice = portal_invoice(%{"rev" => "Y", "itcavl" => "N", "rsn" => "P"})

    assert {:ok, [inv]} = Gstr2b.parse(portal_doc([invoice]))
    assert inv["reverse_charge"] == true
    assert inv["itc_available"] == false
    assert inv["itc_reason"] == "P"
  end

  test "tolerates missing optional fields" do
    invoice = %{"inum" => "X1"}

    assert {:ok, [inv]} = Gstr2b.parse(portal_doc([invoice]))
    assert inv["invoice_date"] == nil
    assert inv["total_paise"] == 0
    assert inv["taxable_paise"] == 0
    assert inv["pos"] == nil
  end

  test "recognizes both portal wrapper shapes without normalizing them" do
    assert Gstr2b.recognized?(portal_doc([]))
    assert Gstr2b.recognized?(%{"docdata" => %{}})
    refute Gstr2b.recognized?(%{"something" => "else"})
  end

  test "rejects undecodable JSON and unrecognized structures" do
    assert {:error, :invalid_json} = Gstr2b.parse("{nope")
    assert {:error, :unrecognized_structure} = Gstr2b.parse(%{"something" => "else"})
    assert {:error, :unrecognized_structure} = Gstr2b.parse(42)
  end
end
