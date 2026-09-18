defmodule Nila.Gst.Portal.TaxpayerWorker do
  use Oban.Worker,
    queue: :workflows,
    max_attempts: 3,
    unique: [
      period: 3600,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable, :suspended, :completed, :discarded]
    ]

  @impl true
  def perform(%Oban.Job{args: %{"org_id" => org_id, "gstin" => gstin}}) do
    result = Nila.Gst.Portal.lookup_taxpayer(gstin)
    if match?({:ok, _}, result), do: Nila.Gst.Sales.TaxpayerChecks.refresh_reviews(gstin)
    Nila.Gst.Intake.Progress.broadcast(org_id, {:gst_taxpayer_checked, gstin})

    case result do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
