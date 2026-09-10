defmodule Nila.Gst.LineRateTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.LineRate

  test "uses printed CGST and SGST rates for line math" do
    assert LineRate.line_rate(%{"cgst_rate" => 9, "sgst_rate" => 9}) == {:ok, 18.0}
  end

  test "derives a rate when printed rate heads are absent" do
    line = %{"taxable_paise" => 10_000, "tax_paise" => %{"cgst" => 900, "sgst" => 900}}
    assert LineRate.line_rate(line) == {:ok, 18.0}
  end
end
