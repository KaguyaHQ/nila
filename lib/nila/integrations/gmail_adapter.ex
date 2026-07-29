defmodule Nila.Integrations.GmailAdapter do
  @moduledoc """
  Contract for the configured Gmail implementation.
  """

  alias Nila.Integrations.Connection

  @callback authorize_url(keyword()) :: String.t()
  @callback exchange_code(String.t()) :: {:ok, map()} | {:error, term()}
  @callback profile_email(String.t()) :: {:ok, String.t()} | {:error, term()}
  @callback refresh_token(String.t()) :: {:ok, map()} | {:error, term()}
  @callback ensure_token(%Connection{}) :: {:ok, %Connection{}} | {:error, term()}
  @callback sync(%Connection{}) :: {:ok, [map()]} | {:error, term()}
  @callback send_message(%Connection{}, String.t(), map()) ::
              {:ok, map()} | {:error, term()}
end
