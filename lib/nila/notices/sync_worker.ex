defmodule Nila.Notices.SyncWorker do
  use Oban.Worker,
    queue: :workflows,
    max_attempts: 1,
    unique: [period: :infinity, fields: [:worker, :args], states: :incomplete]

  @impl true
  def perform(%Oban.Job{args: %{"org_id" => org_id, "client_id" => client_id}}) do
    try do
      case Nila.Notices.sync(org_id, client_id) do
        {:ok, _} -> :ok
        {:error, _} -> :ok
      end
    rescue
      error ->
        Nila.Notices.record_failure(org_id, client_id, :unavailable)
        reraise error, __STACKTRACE__
    end
  end
end
