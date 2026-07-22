defmodule Nila.LineClassificationTest do
  use ExUnit.Case, async: true

  alias Nila.LineClassification

  describe "default_kind/1" do
    test "SAC codes (99xxxx) are services" do
      assert LineClassification.default_kind("998719") == "service"
      assert LineClassification.default_kind("9954") == "service"
    end

    test "HSN codes and anything else are goods" do
      assert LineClassification.default_kind("29037100") == "goods"
      assert LineClassification.default_kind("84158300") == "goods"
      assert LineClassification.default_kind("") == "goods"
      assert LineClassification.default_kind(nil) == "goods"
    end
  end

  describe "valid_uqc?/1" do
    test "recognizes canonical UQCs case-insensitively" do
      assert LineClassification.valid_uqc?("NOS")
      assert LineClassification.valid_uqc?("nos")
      assert LineClassification.valid_uqc?(" kgs ")
    end

    test "rejects free-text units" do
      refute LineClassification.valid_uqc?("EA")
      refute LineClassification.valid_uqc?("job")
      refute LineClassification.valid_uqc?(nil)
    end
  end

  describe "uqc_code_options/0" do
    test "is {code, code} pairs sorted by code" do
      options = LineClassification.uqc_code_options()
      assert {"NOS", "NOS"} in options
      assert {"BAG", "BAG"} in options
      assert options == Enum.sort(options)
      assert Enum.all?(options, fn {label, value} -> label == value end)
    end
  end

  describe "normalize_uqc/1" do
    test "maps extraction synonyms onto canonical UQCs" do
      assert LineClassification.normalize_uqc("EA") == "NOS"
      assert LineClassification.normalize_uqc("each") == "NOS"
      assert LineClassification.normalize_uqc("PC") == "PCS"
      assert LineClassification.normalize_uqc("kg") == "KGS"
    end

    test "passes an already-valid UQC through unchanged" do
      assert LineClassification.normalize_uqc("NOS") == "NOS"
      assert LineClassification.normalize_uqc(" mtr ") == "MTR"
    end

    test "leaves an unrecognized unit upcased (still invalid) for the changeset to reject" do
      result = LineClassification.normalize_uqc("turds")
      assert result == "TURDS"
      refute LineClassification.valid_uqc?(result)
    end
  end
end
