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
    assert Money.decimal_or_error("invoice 12.00") == :unreadable
  end

  test "exposes the same strict parser for normalized legacy JSON numbers" do
    assert Money.rupee_number(1275) === 1275
    assert Money.rupee_number("1,275.125") == 1275.125
    assert Money.rupee_number("1.0e3") == 1000.0
    assert Money.rupee_number("1,2SO.OO") == nil
  end

  test "converts paise back to an exact Decimal rupee value" do
    assert Money.rupees(127_509) == Decimal.new("1275.09")
  end
end
