defmodule Nila.Gst.Sales.OutputCapabilitiesTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Extraction.Sales.Normalizer
  alias Nila.Gst.Sales.OutputCapabilities
  alias Nila.Gst.Sales.Gstr1.Readiness, as: Gstr1Readiness
  alias Nila.Gst.Sales.Tally.Readiness, as: TallyReadiness

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
