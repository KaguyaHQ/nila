defmodule Nila.RateLimiterTest do
  use ExUnit.Case, async: false

  alias Nila.RateLimiter

  test "allows requests below the limit" do
    bucket = bucket()

    assert RateLimiter.check(bucket, 60_000, 2) == :allow
    assert RateLimiter.check(bucket, 60_000, 2) == :allow
  end

  test "denies requests above the limit" do
    bucket = bucket()

    assert RateLimiter.check(bucket, 60_000, 1) == :allow
    assert RateLimiter.check(bucket, 60_000, 1) == :deny
  end

  @tag :capture_log
  test "fails open when the limiter backend is unavailable" do
    bucket = bucket()

    :ok = Application.stop(:hammer)
    on_exit(fn -> {:ok, _apps} = Application.ensure_all_started(:hammer) end)

    assert RateLimiter.check(bucket, 60_000, 1) == :allow
  end

  defp bucket do
    "test:#{System.unique_integer([:positive])}"
  end
end
