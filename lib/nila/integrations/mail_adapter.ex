defmodule Nila.Integrations.MailAdapter do
  @moduledoc """
  Contract every outbound mail provider satisfies.

  Deliberately smaller than any single provider's surface: the chase only needs
  a live token and a send. How a provider earns that token — an offline grant it
  refreshes, or an app-only grant it re-mints — stays behind `ensure_token/1`.
  """

  alias Nila.Integrations.Connection

  @callback ensure_token(%Connection{}) :: {:ok, %Connection{}} | {:error, term()}
  @callback send_message(%Connection{}, String.t(), map()) :: {:ok, map()} | {:error, term()}
end
