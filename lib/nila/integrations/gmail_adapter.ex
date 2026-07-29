defmodule Nila.Integrations.GmailAdapter do
  @moduledoc """
  Contract for the configured Gmail implementation.

  Covers the authorization-code flow and attachment sync specific to Gmail.
  Implementations also satisfy `Nila.Integrations.MailAdapter`.
  """

  alias Nila.Integrations.Connection

  @callback authorize_url(keyword()) :: String.t()
  @callback exchange_code(String.t()) :: {:ok, map()} | {:error, term()}
  @callback profile_email(String.t()) :: {:ok, String.t()} | {:error, term()}
  @callback refresh_token(String.t()) :: {:ok, map()} | {:error, term()}
  @callback sync(%Connection{}) :: {:ok, [map()]} | {:error, term()}
end
