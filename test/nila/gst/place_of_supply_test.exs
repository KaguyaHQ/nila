defmodule Nila.Gst.PlaceOfSupplyTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.PlaceOfSupply

  defp inputs(attrs) do
    Enum.into(attrs, %{
      line_kinds: ["goods"],
      ship_to_state: nil,
      buyer_registration_state: nil,
      seller_state: "Tamil Nadu"
    })
  end

  describe "goods" do
    test "resolve to the bill-to (buyer registration) state in a bill-to-ship-to" do
      # §10(1)(b): the OEM bills from Maharashtra and directs delivery to a
      # Karnataka site — place of supply follows the bill-to (Maharashtra), not
      # the physical ship-to. This is the case the old ship-to rule got wrong.
      assert {:ok, "Maharashtra"} =
               PlaceOfSupply.derive_pos(
                 inputs(
                   line_kinds: ["goods"],
                   ship_to_state: "Karnataka",
                   buyer_registration_state: "Maharashtra"
                 )
               )
    end

    test "fall back to the ship-to state when there is no registered buyer" do
      assert {:ok, "Karnataka"} =
               PlaceOfSupply.derive_pos(inputs(line_kinds: ["goods"], ship_to_state: "Karnataka"))
    end

    test "are ambiguous when neither buyer nor ship-to state is known" do
      assert :ambiguous =
               PlaceOfSupply.derive_pos(inputs(line_kinds: ["goods"], ship_to_state: nil))
    end
  end

  describe "services" do
    test "resolve to the buyer registration state, not the ship-to state" do
      assert {:ok, "Tamil Nadu"} =
               PlaceOfSupply.derive_pos(
                 inputs(
                   line_kinds: ["service"],
                   ship_to_state: "Karnataka",
                   buyer_registration_state: "Tamil Nadu"
                 )
               )
    end

    test "are ambiguous when the buyer registration state is missing" do
      assert :ambiguous =
               PlaceOfSupply.derive_pos(
                 inputs(line_kinds: ["service"], buyer_registration_state: nil)
               )
    end
  end

  describe "mixed documents" do
    test "goods and services to the same state resolve cleanly" do
      assert {:ok, "Tamil Nadu"} =
               PlaceOfSupply.derive_pos(
                 inputs(
                   line_kinds: ["goods", "service"],
                   ship_to_state: "Tamil Nadu",
                   buyer_registration_state: "Tamil Nadu"
                 )
               )
    end

    test "a registered buyer converges goods and services even when the site differs" do
      # The bill-to-ship-to case that used to manufacture a spurious split:
      # buyer in Tamil Nadu, site in Karnataka. Both goods (§10(1)(b)) and
      # services (§12(2)) now follow the bill-to, so one invoice holds one
      # treatment — no divergence.
      assert {:ok, "Tamil Nadu"} =
               PlaceOfSupply.derive_pos(
                 inputs(
                   line_kinds: ["goods", "service"],
                   ship_to_state: "Karnataka",
                   buyer_registration_state: "Tamil Nadu"
                 )
               )
    end

    test "a mixed document with no registered buyer is ambiguous (service has no state)" do
      # goods → ship-to (Karnataka), but service → buyer (blank): one input is
      # missing, so the caller falls back to the explicit override rather than
      # stamping a half-derived place of supply.
      assert :ambiguous =
               PlaceOfSupply.derive_pos(
                 inputs(
                   line_kinds: ["goods", "service"],
                   ship_to_state: "Karnataka",
                   buyer_registration_state: nil
                 )
               )
    end
  end

  test "no lines is ambiguous" do
    assert :ambiguous = PlaceOfSupply.derive_pos(inputs(line_kinds: []))
    assert :ambiguous = PlaceOfSupply.derive_pos(%{})
  end
end
