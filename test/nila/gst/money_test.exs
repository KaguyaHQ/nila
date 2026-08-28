defmodule Nila.Gst.MoneyTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Money

  test "converts every supported rupee representation to exact paise" do
    assert Money.paise_or_error(104.74) == {:ok, 10_474}
    assert Money.paise_or_error(104) == {:ok, 10_400}
    assert Money.paise_or_error("Rs. 1,275.09") == {:ok, 127_509}
    assert Money.paise_or_error(Decimal.new("1275.09")) == {:ok, 127_509}
  end

  test "preserves missing and unreadable outcomes" do
    assert Money.paise_or_error(nil) == :missing
    assert Money.paise_or_error("  ") == :missing
    assert Money.paise_or_error("1,2SO.OO") == :unreadable
  end

  test "converts paise back to an exact Decimal rupee value" do
    assert Money.rupees(127_509) == Decimal.new("1275.09")
  end
end
