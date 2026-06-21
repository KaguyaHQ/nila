defmodule Nila.Integrations.Connector do
  @moduledoc """
  Contract for inbound connectors.
  """

  @callback normalize(raw :: map(), opts :: keyword()) ::
              {:ok, [map()]} | {:error, term()}
end
