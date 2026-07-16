defmodule Nila.Gst.Calendar do
  @moduledoc """
  The GST compliance clock for a tax month. Filing dates for a period
  `"YYYY-MM"` fall in the FOLLOWING month: GSTR-1 is due the 11th, the portal
  generates GSTR-2B by ~the 14th, GSTR-3B is due the 20th. Pure functions of
  the period string and an explicit `today`, so the cockpit's days-left
  numbers are trivially testable.
  """

  @doc """
  The filing dates for a tax period, all in the month after `period`.

      iex> Nila.Gst.Calendar.due_dates("2025-10")
      %{gstr1: ~D[2025-11-11], gstr2b_expected: ~D[2025-11-14], gstr3b: ~D[2025-11-20]}
  """
  def due_dates(period) do
    base = filing_month(period)

    %{
      gstr1: %{base | day: 11},
      gstr2b_expected: %{base | day: 14},
      gstr3b: %{base | day: 20}
    }
  end

  @doc """
  Where the period stands relative to `today`: the due dates plus signed
  days-left counts (negative = overdue) and whether the portal's GSTR-2B
  should already be available.
  """
  def status(period, %Date{} = today) do
    dates = due_dates(period)

    %{
      gstr1_due: dates.gstr1,
      gstr3b_due: dates.gstr3b,
      gstr1_days_left: Date.diff(dates.gstr1, today),
      gstr3b_days_left: Date.diff(dates.gstr3b, today),
      gstr2b_available?: Date.compare(today, dates.gstr2b_expected) != :lt
    }
  end

  defp filing_month(period) do
    [year, month] = period |> String.split("-") |> Enum.map(&String.to_integer/1)

    Date.new!(year, month, 1)
    |> Date.end_of_month()
    |> Date.add(1)
  end
end
