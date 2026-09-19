defmodule Nila.Gst.Portal.StatementWorker do
  use Oban.Worker,
    queue: :workflows,
    max_attempts: 1,
    unique: [period: :infinity, fields: [:worker, :args], states: :incomplete]

  @impl true
  def perform(%Oban.Job{args: %{"org_id" => org_id, "statement_id" => id}}) do
    try do
      case Nila.Gst.Portal.Gstr2b.sync(org_id, id) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    rescue
      error ->
        Nila.Gst.Portal.Gstr2b.record_failure(org_id, id, :unavailable)
        reraise error, __STACKTRACE__
    after
      Nila.Gst.Portal.Gstr2b.notify(org_id, id)
    end
  end
end
