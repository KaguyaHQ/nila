defmodule Nila.Integrations.WhatsAppAdapter do
  @moduledoc """
  Contract for the configured WhatsApp implementation.
  """

  alias Nila.Integrations.Connection

  @callback normalize(map(), keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback fetch_media(String.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  @callback send_message(%Connection{}, String.t(), String.t(), String.t()) ::
              {:ok, map()} | {:error, term()}
end
