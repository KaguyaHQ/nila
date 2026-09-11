defmodule Nila.Gst.Intake.Progress do
  @moduledoc """
  PubSub notifications for document processing.

  Intake, purchase and sales work share one topic because the month workbench
  watches the same processing queue regardless of which side is being built.
  """

  @doc "Subscribes to processing notifications for an organisation."
  def subscribe(org_id) do
    Phoenix.PubSub.subscribe(Nila.PubSub, topic(org_id))
  end

  @doc "Publishes one processing notification for an organisation."
  def broadcast(org_id, message) do
    Phoenix.PubSub.broadcast(Nila.PubSub, topic(org_id), message)
  end

  defp topic(org_id), do: "gst_month:#{org_id}"
end
