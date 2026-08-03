defmodule Nila.Integrations.GmailAdapter do
  @moduledoc """
  Contract for the configured Gmail implementation.

  Covers only the authorization-code handshake specific to Gmail — the offline
  grant Nila refreshes. Sending is `Nila.Integrations.MailAdapter`, which
  implementations satisfy too; nothing here reads a mailbox.
  """

  @callback authorize_url(keyword()) :: String.t()
  @callback exchange_code(String.t()) :: {:ok, map()} | {:error, term()}
  @callback profile_email(String.t()) :: {:ok, String.t()} | {:error, term()}
  @callback refresh_token(String.t()) :: {:ok, map()} | {:error, term()}
end
