defmodule Nila.Gst.Sales.OutputCapabilitiesTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Sales.{Gstr1, Gstr1Readiness, OutputCapabilities, TallyReadiness}

  test "GSTR-1 and Tally consume the same shared capability findings" do
    invoice =
      Gstr1.normalize_invoice(%{
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

    assert gstr1_codes == shared_codes
    assert tally_codes == shared_codes
  end

  test "GSTR-1 retains its destination-specific CDnur boundary" do
    note =
      Gstr1.normalize_invoice(%{
        "document" => %{"credit_note" => true},
        "data" => %{
          "document_type" => "credit_note",
          "invoice_number" => "CN-1",
          "recipient_registration" => "unregistered",
          "line_items" => []
        }
      })

    assert OutputCapabilities.common(note) == []
    assert codes(Gstr1Readiness.capability_issues([note])) == ["cdnur_unsupported"]
    assert TallyReadiness.issues([note]) == []
  end

  defp codes(issues), do: Enum.map(issues, & &1["code"])
end
