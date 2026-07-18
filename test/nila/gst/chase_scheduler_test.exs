defmodule Nila.Gst.ChaseSchedulerTest do
  use Nila.DataCase, async: true
  use Oban.Testing, repo: Nila.Repo

  import Nila.AccountsFixtures

  alias Nila.Clients
  alias Nila.Gst.{Calendar, ChaseScheduler, ChaseSender}

  @today ~D[2026-07-17]

  test "policy sends fresh asks and applies far and near deadline cadence" do
    assert ChaseScheduler.should_ask?(row(nil, 10, 0), @today)
    assert ChaseScheduler.should_ask?(row(days_ago(4), 7, 1), @today)
    refute ChaseScheduler.should_ask?(row(days_ago(3), 7, 1), @today)
    assert ChaseScheduler.should_ask?(row(days_ago(2), 6, 1), @today)
    refute ChaseScheduler.should_ask?(row(days_ago(1), 6, 1), @today)
  end

  test "policy stops at four asks and when there is no engine draft" do
    refute ChaseScheduler.should_ask?(row(days_ago(20), 1, 4), @today)
    refute ChaseScheduler.should_ask?(%{row(nil, 10, 0) | draft: nil}, @today)
  end

  test "scheduler uses Today's waiting-on-client worklist" do
    org = org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Ravi Traders",
        type: "company",
        phone: "9876543210",
        chase_channel: "whatsapp"
      })

    assert :ok = perform_job(ChaseScheduler, %{})

    period = Calendar.closeable_period(Date.utc_today())

    assert_enqueued(
      worker: ChaseSender,
      args: %{
        org_id: org.id,
        client_id: client.id,
        period: period,
        channel: "whatsapp",
        kind: "month_open"
      }
    )
  end

  defp row(last_ask_at, days_left, ask_count) do
    %{
      draft: %{kind: "month_open", body: "Please send the files."},
      last_ask_at: last_ask_at,
      deadline: %{days_left: days_left},
      ask_count: ask_count
    }
  end

  defp days_ago(days), do: DateTime.new!(Date.add(@today, -days), ~T[09:00:00], "Etc/UTC")
end
