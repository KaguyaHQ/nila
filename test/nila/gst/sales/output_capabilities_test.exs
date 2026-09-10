defmodule Nila.Gst.Sales.OutputCapabilitiesTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Extraction.Sales.Normalizer
  alias Nila.Gst.Sales.OutputCapabilities
  alias Nila.Gst.Sales.Gstr1.Readiness, as: Gstr1Readiness
  alias Nila.Gst.Sales.Tally.Readiness, as: TallyReadiness

  test "supported GSTR-1 treatments retain their Tally-only restrictions" do
    for {supply, reverse_charge, code} <- [
          {"export", false, "export_supply_unsupported"},
          {"sez", false, "sez_supply_unsupported"},
          {"nil_rated", false, "nil_rated_supply_unsupported"},
          {"exempt", false, "exempt_supply_unsupported"},
          {"non_gst", false, "non_gst_supply_unsupported"},
          {"taxable", true, "outward_reverse_charge_unsupported"}
        ] do
      invoice =
        Normalizer.normalize(%{
          "data" => %{
            "invoice_number" => "SPECIAL-1",
            "supply_type" => supply,
            "reverse_charge" => reverse_charge,
            "recipient_registration" =>
              if(supply == "export", do: "unregistered", else: "registered"),
            "buyer_gstin" => if(supply == "export", do: nil, else: "29AABCT1332L1Z5"),
            "tax_payment" => if(supply in ~w(export sez), do: "with_payment"),
            "line_items" => []
          }
        })

      assert Gstr1Readiness.capability_issues([invoice]) == [], code
      assert codes(TallyReadiness.issues([invoice])) == [code]
      assert Nila.Gst.Issues.level_for(code) == "blocking"
    end
  end

  test "cancelled and amendment documents remain restricted in both outputs" do
    for status <- ~w(cancelled amendment) do
      invoice =
        Normalizer.normalize(%{
          "data" => %{
            "invoice_number" => "STATUS-1",
            "document_status" => status,
            "line_items" => []
          }
        })

      expected = ["#{status}_document_unsupported"]
      assert codes(Gstr1Readiness.capability_issues([invoice])) == expected
      assert codes(TallyReadiness.issues([invoice])) == expected
    end
  end

  test "GSTR-1 validates special treatments while Tally retains its capability blockers" do
    invoice =
      Normalizer.normalize(%{
        "document" => %{"export" => true, "reverse_charge" => true},
        "data" => %{
          "invoice_number" => "EXP-1",
          "document_status" => "cancelled",
          "supply_type" => "export",
          "line_items" => []
        }
      })

    shared_codes = invoice |> OutputCapabilities.common() |> Enum.map(& &1.code)
    gstr1_codes = invoice |> then(&Gstr1Readiness.capability_issues([&1])) |> codes()
    tally_codes = invoice |> then(&TallyReadiness.issues([&1])) |> codes()

    assert shared_codes == [
             "export_supply_unsupported",
             "outward_reverse_charge_unsupported",
             "cancelled_document_unsupported"
           ]

    assert gstr1_codes == [
             "cancelled_document_unsupported",
             "missing_tax_payment",
             "special_supply_conflict"
           ]

    assert tally_codes == shared_codes
  end

  test "GSTR-1 requires the original interstate sale category independently of Tally" do
    note =
      Normalizer.normalize(%{
        "document" => %{"credit_note" => true},
        "data" => %{
          "document_type" => "credit_note",
          "invoice_number" => "CN-1",
          "recipient_registration" => "unregistered",
          "seller_gstin" => "33BPBPK1081A1ZO",
          "place_of_supply" => "29",
          "line_items" => []
        }
      })

    assert OutputCapabilities.common(note) == []
    assert codes(Gstr1Readiness.capability_issues([note])) == ["missing_original_sale_category"]
    assert TallyReadiness.issues([note]) == []
  end

  defp codes(issues), do: Enum.map(issues, & &1["code"])
end
