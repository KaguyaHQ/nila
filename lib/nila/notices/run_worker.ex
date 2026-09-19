defmodule Nila.Notices.RunWorker do
  use Oban.Worker, queue: :workflows, max_attempts: 1

  @impl true
  def perform(%Oban.Job{id: job_id, args: %{"run_id" => run_id, "client_id" => client_id}}) do
    Nila.Notices.Runs.perform(run_id, client_id, job_id)
  rescue
    error ->
      Nila.Notices.Runs.finish(run_id, client_id, job_id, {:error, :unavailable})
      reraise error, __STACKTRACE__
  end
end
