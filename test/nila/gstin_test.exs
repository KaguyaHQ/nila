defmodule Nila.GstinTest do
  use ExUnit.Case, async: true

  alias Nila.Gstin

  describe "valid?/1" do
    test "accepts well-formed GSTINs with a correct check digit" do
      assert Gstin.valid?("33AABCP9487A1ZG")
      assert Gstin.valid?("33AAVCS8021P1ZM")
    end

    test "rejects a wrong check digit" do
      refute Gstin.valid?("33AABCZ9377E1ZW")
    end

    test "rejects structurally malformed input" do
      refute Gstin.valid?("Un registered Person")
      refute Gstin.valid?("33AABCP9487A1Z")
      refute Gstin.valid?("330ABCP9487A1ZG")
    end

    test "rejects non-string and blank input" do
      refute Gstin.valid?(nil)
      refute Gstin.valid?("")
      refute Gstin.valid?(12_345)
    end

    test "trims surrounding whitespace before validating" do
      assert Gstin.valid?("  33AABCP9487A1ZG  ")
    end
  end

  describe "validate_gstin/2" do
    import Ecto.Changeset

    defp changeset(attrs) do
      {%{}, %{gstin: :string}}
      |> cast(attrs, [:gstin])
      |> Gstin.validate_gstin(:gstin)
    end

    test "valid GSTIN passes" do
      assert changeset(%{gstin: "33AABCP9487A1ZG"}).valid?
    end

    test "nil and blank pass through" do
      assert changeset(%{gstin: nil}).valid?
      assert changeset(%{gstin: ""}).valid?
    end

    test "invalid GSTIN adds an error" do
      cs = changeset(%{gstin: "33AABCZ9377E1ZW"})
      refute cs.valid?
      assert {"is not a valid GSTIN", _} = cs.errors[:gstin]
    end
  end

  describe "repair/1" do
    test "corrects a scan-damaged GSTIN when the grammar and check digit leave one reading" do
      # Real capture from breeze 2026-06 page 22: the scanner read Alleppey Techno
      # Care's GSTIN with a digit 1 where the format demands a letter.
      assert Gstin.repair("32ABSP14532L1ZG") == {:repaired, "32ABSPI4532L1ZG"}
      assert Gstin.valid?("32ABSPI4532L1ZG")
    end

    test "corrects a letter read as a digit in the numeric run" do
      assert Gstin.repair("33AENFS082OH1Z6") == {:repaired, "33AENFS0820H1Z6"}
    end

    test "passes a valid GSTIN through untouched" do
      assert Gstin.repair("33AEWPH4158J1Z3") == {:ok, "33AEWPH4158J1Z3"}
    end

    test "refuses when the damage is not a substitution" do
      # A dropped character (14 chars) and a mangled tail: no single reading is
      # implied, and guessing a supplier's identity is worse than flagging it.
      assert Gstin.repair("33AEWPH4158JZ3") == :error
      assert Gstin.repair("33A-EWPH41587123") == :error
    end

    test "refuses nonsense rather than inventing a supplier" do
      assert Gstin.repair("") == :error
      assert Gstin.repair(nil) == :error
      assert Gstin.repair("HELLO") == :error
    end
  end
end
