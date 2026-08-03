defmodule Nila.Integrations.MailAdapter do
  @moduledoc """
  Contract every outbound mail provider satisfies.

  Deliberately smaller than any single provider's surface: the chase only needs
  a live token and a send. How a provider earns that token — an offline grant it
  refreshes, or an app-only grant it re-mints — stays behind `ensure_token/1`.

  The message map carries `:subject` and `:body`, and may carry `:reply_to`.
  An implementation that drops `:reply_to` still sends mail, so the omission
  is invisible until a client replies and the answer lands nowhere Nila can
  attribute it — see `Nila.Gst.Intake.InboundAddress`. Honour it.
  """

  alias Nila.Integrations.Connection

  @callback ensure_token(%Connection{}) :: {:ok, %Connection{}} | {:error, term()}
  @callback send_message(%Connection{}, String.t(), map()) :: {:ok, map()} | {:error, term()}
end
