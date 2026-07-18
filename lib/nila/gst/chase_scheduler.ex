defmodule Nila.Gst.ChaseScheduler do
  use Oban.Worker, queue: :chase, max_attempts: 1

  require Logger

  alias Nila.Gst.{ChaseSender, Today}
  alias Nila.Orgs

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    today = Date.utc_today()

    for org <- Orgs.list_orgs(),
        row <- Today.rows(org.id, today),
        row.section == :waiting_on_client,
        row.chase_channel != "none",
        should_ask?(row, today) do
      case ChaseSender.enqueue(row) do
        {:ok, _job} ->
          :ok

        {:error, reason} ->
          Logger.warning("GST chase enqueue failed",
            org_id: org.id,
            client_id: row.client_id,
            period: row.period,
            channel: row.chase_channel,
            reason: inspect(reason)
          )
      end
    end

    :ok
  end

  def should_ask?(%{draft: nil}, _today), do: false
  def should_ask?(%{deadline: nil}, _today), do: false
  def should_ask?(%{ask_count: count}, _today) when count >= 4, do: false
  def should_ask?(%{last_ask_at: nil}, _today), do: true

  def should_ask?(row, %Date{} = today) do
    days_since_ask = Date.diff(today, DateTime.to_date(row.last_ask_at))
    interval = if row.deadline.days_left < 7, do: 2, else: 4
    days_since_ask >= interval
  end
end
