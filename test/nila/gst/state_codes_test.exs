defmodule Nila.Gst.StateCodesTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.StateCodes

  test "derives the leading state code from GSTIN text" do
    assert StateCodes.from_gstin("33AABCP9487A1ZG") == "33"
    assert StateCodes.from_gstin(" 29AAVCS8021P1ZB ") == "29"
    assert StateCodes.from_gstin(nil) == nil
    assert StateCodes.from_gstin("3") == nil
  end
end
