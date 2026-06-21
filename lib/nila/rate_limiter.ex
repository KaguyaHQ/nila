defmodule Nila.RateLimiter do
  @moduledoc """
  Application boundary for request rate limiting.

  Hammer exits when its backend pool is unavailable, so callers should use this
  module instead of calling Hammer directly. Nila fails open for limiter outages:
  a missing limiter should not take down a user workflow.
  """

  require Logger

  def check(bucket, scale_ms, limit) do
    case check_with_hammer(bucket, scale_ms, limit) do
      {:allow, _count} ->
        :allow

      {:deny, _limit} ->
        :deny

      {:error, reason} ->
        Logger.warning(
          "Rate limiter unavailable; allowing request bucket=#{inspect(bucket)} reason=#{inspect(reason)}"
        )

        :allow
    end
  end

  defp check_with_hammer(bucket, scale_ms, limit) do
    Hammer.check_rate(bucket, scale_ms, limit)
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end
