defmodule Nila.Gst.Filing.Gstr2bTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Filing.Gstr2b

  @gstin_a "33AAACS1234A1Z9"

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

  defp portal_doc(invoices) do
    %{
      "data" => %{
        "docdata" => %{
          "b2b" => [
            %{"ctin" => @gstin_a, "trdnm" => "Sharma Steels", "inv" => invoices}
          ]
        }
      }
    }
  end

  test "normalizes a documented-shape invoice into paise maps" do
    assert {:ok, [inv]} = Gstr2b.parse(portal_doc([portal_invoice()]))

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
