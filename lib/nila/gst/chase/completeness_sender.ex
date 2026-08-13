defmodule Nila.Gst.Chase.CompletenessSender do
  @moduledoc false

  # Kept only so jobs queued before the completeness-confirmation workflow was
  # removed terminate cleanly after a deploy. Nothing schedules new jobs.
  use Oban.Worker, queue: :notifications, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: {:cancel, :feature_removed}
end
