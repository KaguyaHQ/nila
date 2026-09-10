defmodule Nila.Gst.DatesTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Dates

  describe "parse_date/1" do
    test "reads native Tally month abbreviations without accepting invalid dates" do
      assert Dates.parse_date("15-Jan-26") == ~D[2026-01-15]
      assert Dates.parse_date("1-SEP-2026") == ~D[2026-09-01]
      assert Dates.parse_date("29-Feb-24") == ~D[2024-02-29]
      assert Dates.parse_date("31-Apr-26") == nil
      assert Dates.parse_date("29-Feb-25") == nil
      assert Dates.parse_date("15-Abc-26") == nil
      assert Dates.parse_date("15-Jan-202") == nil
    end

    test "parses printed formats" do
      assert ~D[2025-10-08] = Dates.parse_date("08.10.2025")
      assert ~D[2025-10-08] = Dates.parse_date("08/10/2025")
      assert ~D[2025-10-08] = Dates.parse_date("8-10-25")
      assert ~D[2025-10-08] = Dates.parse_date("2025-10-08")
      assert ~D[2025-10-08] = Dates.parse_date("Date: 08/10/2025 7:32PM")
    end

    test "garbage is nil" do
      assert Dates.parse_date("октябрь") == nil
      assert Dates.parse_date("99.99.2025") == nil
      assert Dates.parse_date(nil) == nil
    end
  end
end
