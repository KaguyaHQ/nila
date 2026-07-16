defmodule Nila.Gst.CalendarTest do
  use ExUnit.Case, async: true

  doctest Nila.Gst.Calendar

  alias Nila.Gst.Calendar

  test "due_dates/1 lands on the 11th/14th/20th of the following month" do
    assert Calendar.due_dates("2025-10") == %{
             gstr1: ~D[2025-11-11],
             gstr2b_expected: ~D[2025-11-14],
             gstr3b: ~D[2025-11-20]
           }
  end

  test "due_dates/1 rolls a December period into January of the next year" do
    assert Calendar.due_dates("2025-12") == %{
             gstr1: ~D[2026-01-11],
             gstr2b_expected: ~D[2026-01-14],
             gstr3b: ~D[2026-01-20]
           }
  end

  test "status/2 before the GSTR-1 due date: positive days, no 2B yet" do
    status = Calendar.status("2025-10", ~D[2025-11-05])

    assert status == %{
             gstr1_due: ~D[2025-11-11],
             gstr3b_due: ~D[2025-11-20],
             gstr1_days_left: 6,
             gstr3b_days_left: 15,
             gstr2b_available?: false
           }
  end

  test "status/2 after the 14th: 2B is available" do
    status = Calendar.status("2025-10", ~D[2025-11-14])

    assert status.gstr2b_available?
    assert status.gstr1_days_left == -3
    assert status.gstr3b_days_left == 6
  end

  test "status/2 past the 3B due date goes negative" do
    status = Calendar.status("2025-10", ~D[2025-11-25])

    assert status.gstr1_days_left == -14
    assert status.gstr3b_days_left == -5
    assert status.gstr2b_available?
  end
end
