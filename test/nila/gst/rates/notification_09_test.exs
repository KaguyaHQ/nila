defmodule Nila.Gst.Rates.Notification09Test do
  use ExUnit.Case, async: true

  alias Nila.Gst.Rates.Notification09

  @schedule_counts [
    {"I", "5", 516},
    {"II", "18", 640},
    {"III", "40", 13},
    {"IV", "3", 15},
    {"V", "0.25", 3},
    {"VI", "1.50", 2},
    {"VII", "28", 6}
  ]

  test "parses every expected schedule and preserves simple, excluded and conditional scopes" do
    assert {:ok, parsed} = Notification09.parse(notification_text())

    assert parsed.metadata == %{
             notification_number: "9/2025-Integrated Tax (Rate)",
             tax_type: "integrated",
             published_on: ~D[2025-09-17],
             effective_from: ~D[2025-09-22]
           }

    assert length(parsed.rules) == 1_195

    silver = Enum.find(parsed.rules, &(&1.schedule == "IV" and &1.serial_number == 3))
    assert silver.total_rate == Decimal.new("3")
    assert silver.raw_code_expression == "7106"
    assert silver.parsed_scope["includes"] == ["7106"]
    assert silver.parser_confidence == "automatic"

    excluded = Enum.find(parsed.rules, &(&1.schedule == "I" and &1.serial_number == 15))
    assert excluded.parsed_scope["includes"] == ["0507"]
    assert excluded.parsed_scope["excludes"] == ["050790"]

    welding = Enum.find(parsed.rules, &(&1.schedule == "II" and &1.serial_number == 385))
    assert welding.parser_confidence == "review"
  end

  test "rejects a partial extraction rather than staging a plausible-looking subset" do
    partial = """
    NO. 9/2025-Integrated Tax (Rate)
    New Delhi, the 17th September, 2025
    This notification shall come into force with effect from the 22nd day of September, 2025.
    Schedule IV – 3%
    1.   7106   Silver
    """

    assert {:error, {:unexpected_schedule_counts, %{"IV" => 1}}} =
             Notification09.parse(partial)
  end

  defp notification_text do
    header = """
    NO. 9/2025-Integrated Tax (Rate)
    New Delhi, the 17th September, 2025
    This notification shall come into force with effect from the 22nd day of September, 2025.
    """

    schedules =
      Enum.map_join(@schedule_counts, "\n", fn {schedule, rate, count} ->
        rows =
          Enum.map_join(1..count, "\n", fn serial ->
            {code, description} = row(schedule, serial)
            "#{serial}.   #{code}   #{description}"
          end)

        "Schedule #{schedule} – #{rate}%\n#{rows}"
      end)

    header <> schedules <> "\nExplanation.— For the purposes of this notification"
  end

  defp row("I", 15), do: {"0507 (Except 050790)", "Ivory"}

  defp row("II", 385) do
    {"8311", "Products of a kind used for soldering or welding"}
  end

  defp row("IV", 3), do: {"7106", "Silver in semi-manufactured forms"}
  defp row(_schedule, _serial), do: {"0101", "Live horses"}
end
