defmodule Nila.Gst.Extraction.ProviderAdmissionTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Extraction.ProviderAdmission

  test "queues requests globally at the configured rate" do
    server =
      start_supervised!(
        {ProviderAdmission, name: nil, tokens_per_minute: 100, requests_per_second: 10}
      )

    first = ProviderAdmission.acquire(10, server)
    started = System.monotonic_time(:millisecond)
    second = ProviderAdmission.acquire(10, server)

    assert is_reference(first)
    assert is_reference(second)
    assert System.monotonic_time(:millisecond) - started >= 80
  end

  test "holds requests above the provider concurrency limit" do
    server =
      start_supervised!(
        {ProviderAdmission,
         name: nil, tokens_per_minute: 100, requests_per_second: 1_000, max_concurrency: 1}
      )

    first = ProviderAdmission.acquire(10, server)
    task = Task.async(fn -> ProviderAdmission.acquire(10, server) end)
    refute Task.yield(task, 30)

    ProviderAdmission.reconcile(first, 10, server)
    assert is_reference(Task.await(task, 500))
  end

  test "reconciled usage holds later requests until the token window expires" do
    server =
      start_supervised!(
        {ProviderAdmission,
         name: nil, tokens_per_minute: 10, requests_per_second: 1_000, max_concurrency: 10}
      )

    reservation = ProviderAdmission.acquire(5, server)
    :ok = ProviderAdmission.reconcile(reservation, 10, server)

    task = Task.async(fn -> ProviderAdmission.acquire(1, server) end)
    refute Task.yield(task, 30)

    ProviderAdmission.release(reservation, 0, server)
    assert is_reference(Task.await(task, 500))
  end
end
