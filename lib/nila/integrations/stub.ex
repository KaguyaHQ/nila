defmodule Nila.Integrations.Stub do
  @behaviour Nila.Integrations.Connector

  @impl true
  def normalize(%{"attachments" => attachments}, _opts) when is_list(attachments) do
    {:ok, attachments}
  end

  def normalize(_raw, _opts), do: {:ok, []}
end
