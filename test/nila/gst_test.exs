defmodule Nila.GstTest do
  use ExUnit.Case, async: true

  alias Nila.Gst

  describe "derive_gst_treatment/2" do
    test "intra-state when seller state matches place of supply" do
      assert :intra_state = Gst.derive_gst_treatment("Tamil Nadu", "Tamil Nadu")
    end

    test "inter-state when seller state differs from place of supply" do
      assert :inter_state = Gst.derive_gst_treatment("Tamil Nadu", "Telangana")
    end

    test "inter-state when either side is nil or non-binary (safer default)" do
      assert :inter_state = Gst.derive_gst_treatment("Tamil Nadu", nil)
      assert :inter_state = Gst.derive_gst_treatment(nil, "Tamil Nadu")
      assert :inter_state = Gst.derive_gst_treatment(nil, nil)
    end
  end

  describe "treatment_to_persisted/1" do
    test "maps jurisdiction atoms to the persisted schema strings" do
      assert Gst.treatment_to_persisted(:intra_state) == "cgst_sgst"
      assert Gst.treatment_to_persisted(:inter_state) == "igst"
    end
  end

  describe "split_tax/2" do
    test "intra-state halves into cgst/sgst, odd paise to cgst" do
      assert {900, 900, 0} = Gst.split_tax(1800, :intra_state)
      assert {451, 450, 0} = Gst.split_tax(901, :intra_state)
    end

    test "intra-state split sums back to the original and stays within 1 paise" do
      {cgst, sgst, igst} = Gst.split_tax(901, :intra_state)
      assert cgst + sgst + igst == 901
      assert abs(cgst - sgst) <= 1
    end

    test "inter-state is all igst" do
      assert {0, 0, 1800} = Gst.split_tax(1800, :inter_state)
    end

    test "zero gst splits to zero regardless of treatment" do
      assert {0, 0, 0} = Gst.split_tax(0, :intra_state)
      assert {0, 0, 0} = Gst.split_tax(0, :inter_state)
    end
  end

  describe "tax_breakdown/5" do
    test "intra-state shows cgst then sgst rows" do
      assert [{"CGST", 900}, {"SGST", 900}] = Gst.tax_breakdown(900, 900, 0, 1800, "GST")
    end

    test "intra-state with one zero side still classifies as cgst/sgst" do
      assert [{"CGST", 0}, {"SGST", 5}] = Gst.tax_breakdown(0, 5, 0, 5, "GST")
    end

    test "inter-state shows a single igst row" do
      assert [{"IGST", 1800}] = Gst.tax_breakdown(0, 0, 1800, 1800, "GST")
    end

    test "no split derived yet falls back to a single labelled row carrying gst" do
      assert [{"GST", 1800}] = Gst.tax_breakdown(0, 0, 0, 1800, "GST")
      assert [{"Total tax", 1800}] = Gst.tax_breakdown(nil, nil, nil, 1800, "Total tax")
    end

    test "fallback uses zero when gst is nil" do
      assert [{"GST", 0}] = Gst.tax_breakdown(nil, nil, nil, nil, "GST")
    end
  end
end
