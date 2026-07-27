defmodule NilaWeb.Gst.PeriodOptions do
  @moduledoc """
  The tax periods a document can be filed under, each labelled with what that
  month already holds: `"Apr 2026 — 14 bills, 2B in"`.

  A bare `{label, period}` list is how a wrong-month upload happens. The intake
  form pre-selects `Calendar.closeable_period/1`, so on the 1st of every month
  the default rolls while the pile on someone's desk does not, and a user
  dropping April's PDF onto a form already reading "June" has to *notice and
  change* a correct-looking field. The form cannot know the dates inside the
  file it is handed — but it can say that June is empty and April is full,
  which is the tell in every wrong-month upload.

  Shared by intake and by the month page's "move this packet" answer, because
  choosing a destination is the same choice with the same trap.
  """

  alias Nila.Formatters
  alias Nila.Gst.Filing.Calendar
  alias Nila.Gst.Intake.Dumps

  @months 36

  @doc "The `#{@months}` selectable periods, newest (the closeable month) first."
  def periods(today \\ Date.utc_today()) do
    <<year::binary-size(4), "-", month::binary-size(2)>> = Calendar.closeable_period(today)
    first_month = String.to_integer(year) * 12 + String.to_integer(month) - 1

    for offset <- 0..(@months - 1) do
      month_index = first_month - offset
      "#{div(month_index, 12)}-#{String.pad_leading(to_string(rem(month_index, 12) + 1), 2, "0")}"
    end
  end

  @doc """
  `{label, period}` options for a `<select>`. With no client picked yet there is
  nothing to report, so the labels stay bare rather than guessing.
  """
  def for_client(org_id, client_id, opts \\ [])

  def for_client(org_id, client_id, opts) when not is_nil(org_id) and not is_nil(client_id) do
    holdings = Dumps.holdings(org_id, client_id)
    except = Keyword.get(opts, :except)

    for period <- periods(), period != except do
      {label(period, holdings[period]), period}
    end
  end

  def for_client(_org_id, _client_id, opts) do
    except = Keyword.get(opts, :except)

    for period <- periods(), period != except, do: {Formatters.period_label(period), period}
  end

  defp label(period, nil), do: "#{Formatters.period_label(period)} — nothing in yet"

  defp label(period, %{bills: bills, gstr2b?: gstr2b?}) do
    held =
      [
        bills > 0 && "#{bills} #{if bills == 1, do: "bill", else: "bills"}",
        gstr2b? && "2B in"
      ]
      |> Enum.filter(& &1)

    case held do
      [] -> "#{Formatters.period_label(period)} — nothing in yet"
      parts -> "#{Formatters.period_label(period)} — #{Enum.join(parts, ", ")}"
    end
  end
end
