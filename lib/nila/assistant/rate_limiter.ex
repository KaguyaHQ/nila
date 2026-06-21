defmodule Nila.Assistant.RateLimiter do
  @moduledoc """
  Rate limits user-submitted assistant messages.
  """

  alias Nila.Accounts.User
  alias Nila.RateLimiter

  @scale_ms 60_000
  @limit 20

  def check_user_message(%User{id: user_id}) do
    RateLimiter.check("assistant:#{user_id}", @scale_ms, @limit)
  end
end
