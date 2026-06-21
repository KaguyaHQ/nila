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
end
