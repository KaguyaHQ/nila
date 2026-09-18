defmodule Nila.Gst.Sales.TaxpayerChecksTest do
  use ExUnit.Case, async: true
  alias Nila.Gst.Sales.TaxpayerChecks

  defp invoice do
    %{
      "id" => "source-1",
      "invoice_number" => "INV-1",
      "buyer_gstin" => "33AEWPH4158J1Z3",
      "buyer_name" => "Breeze Tech",
      "taxpayer_checks" => %{
        "buyer" => %{
          "gstin" => "33AEWPH4158J1Z3",
          "legal_name" => "Breeze Technologies Private Limited",
          "trade_name" => "Breeze Tech",
          "registration_status" => "Active",
          "checked_at" => DateTime.to_iso8601(DateTime.utc_now())
        }
      }
    }
  end

  test "legal and trade names accept harmless punctuation and common company abbreviations" do
    for name <- ["Breeze Tech", "BREEZE-TECH", "Breeze Technologies Pvt. Ltd."] do
      assert TaxpayerChecks.issues([Map.put(invoice(), "buyer_name", name)]) == []
    end
  end

  test "a different name and suspended registration ask for review with dated evidence" do
    checked =
      invoice()
      |> Map.put("buyer_name", "Another Business")
      |> put_in(["taxpayer_checks", "buyer", "registration_status"], "Suspended")

    issues = TaxpayerChecks.issues([checked])

    assert Enum.sort(Enum.map(issues, & &1["code"])) ==
             ["buyer_gst_name_review", "buyer_gst_registration_review"]

    assert Enum.all?(issues, &(&1["level"] == "required" and &1["source_id"] == "source-1"))
    assert Enum.all?(issues, &String.contains?(&1["message"], "not on the invoice date"))
  end

  test "stale, absent or wrong-GSTIN evidence is not a pass or invalid registration" do
    stale =
      invoice()
      |> put_in(
        ["taxpayer_checks", "buyer", "checked_at"],
        DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -30, :day))
      )

    changed = Map.put(invoice(), "buyer_gstin", "33CPWPV2650A1ZQ")
    missing = Map.delete(invoice(), "taxpayer_checks")

    for checked <- [stale, changed, missing] do
      assert TaxpayerChecks.issues([checked]) == []
      assert Enum.all?(TaxpayerChecks.outcomes(checked), &(&1.status == :not_checked))
    end
  end

  test "missing name cannot pass; unregistered buyers do not need portal checks" do
    checked = Map.put(invoice(), "buyer_name", nil)

    assert Enum.find(TaxpayerChecks.outcomes(checked), &(&1.id == "buyer_gst_name_review")).status ==
             :not_checked

    checked = %{"recipient_registration" => "unregistered"}

    assert Enum.filter(TaxpayerChecks.outcomes(checked), &String.starts_with?(&1.id, "buyer"))
           |> Enum.all?(&(&1.status == :not_applicable))
  end
end
