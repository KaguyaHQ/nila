defmodule Nila.Gst.Extraction.ProviderAdmission do
  @moduledoc false

  use GenServer

  @window_ms :timer.minutes(1)

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def acquire(tokens, server \\ __MODULE__) when is_integer(tokens) and tokens >= 0 do
    GenServer.call(server, {:acquire, tokens}, :infinity)
  end

  def reconcile(reservation, actual_tokens, server \\ __MODULE__)
      when is_reference(reservation) and is_integer(actual_tokens) and actual_tokens >= 0 do
    GenServer.call(server, {:reconcile, reservation, actual_tokens})
  end

  def release(reservation, delay_ms, server \\ __MODULE__)
      when is_reference(reservation) and is_integer(delay_ms) and delay_ms >= 0 do
    GenServer.call(server, {:release, reservation, delay_ms})
  end

  @impl true
  def init(opts) do
    config = Application.get_env(:nila, __MODULE__, [])
    now = now_ms()

    {:ok,
     %{
       queue: :queue.new(),
       in_flight: %{},
       usage: %{},
       tokens_per_minute:
         Keyword.get(opts, :tokens_per_minute, config[:tokens_per_minute] || 100_000),
       request_interval_ms:
         request_interval(
           Keyword.get(opts, :requests_per_second, config[:requests_per_second] || 1.67)
         ),
       max_concurrency: Keyword.get(opts, :max_concurrency, config[:max_concurrency] || 100),
       next_request_at: now,
       cooldown_until: now,
       timer: nil
     }}
  end

  @impl true
  def handle_call({:acquire, tokens}, from, state) do
    tokens = min(tokens, state.tokens_per_minute)
    state = %{state | queue: :queue.in({from, tokens}, state.queue)}
    {:noreply, dispatch(state)}
  end

  def handle_call({:reconcile, reservation, actual_tokens}, _from, state) do
    {active, in_flight} = Map.pop(state.in_flight, reservation)

    state =
      if active do
        Process.demonitor(active.monitor, [:flush])

        %{
          state
          | in_flight: in_flight,
            usage:
              Map.put(state.usage, reservation, %{
                tokens: min(actual_tokens, state.tokens_per_minute),
                expires_at: now_ms() + @window_ms
              })
        }
      else
        state
      end

    {:reply, :ok, dispatch(state)}
  end

  def handle_call({:release, reservation, delay_ms}, _from, state) do
    {active, in_flight} = Map.pop(state.in_flight, reservation)
    if active, do: Process.demonitor(active.monitor, [:flush])

    state = %{
      state
      | in_flight: in_flight,
        usage: Map.delete(state.usage, reservation),
        cooldown_until: max(state.cooldown_until, now_ms() + delay_ms)
    }

    {:reply, :ok, dispatch(state)}
  end

  @impl true
  def handle_info({:dispatch, tag}, %{timer: {tag, _timer_ref}} = state),
    do: {:noreply, dispatch(%{state | timer: nil})}

  def handle_info({:dispatch, _stale}, state), do: {:noreply, state}

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    in_flight =
      Map.reject(state.in_flight, fn {_reservation, active} -> active.monitor == monitor end)

    {:noreply, dispatch(%{state | in_flight: in_flight})}
  end

  defp dispatch(state) do
    state = state |> cancel_timer() |> expire_usage()

    case :queue.peek(state.queue) do
      :empty ->
        state

      {:value, {from, tokens}} ->
        now = now_ms()
        used = used_tokens(state)

        if eligible?(state, used, tokens, now) do
          {{:value, {^from, ^tokens}}, queue} = :queue.out(state.queue)
          reservation = make_ref()
          {pid, _reply_tag} = from

          state = %{
            state
            | queue: queue,
              in_flight:
                Map.put(state.in_flight, reservation, %{
                  tokens: tokens,
                  monitor: Process.monitor(pid)
                }),
              next_request_at: now + state.request_interval_ms
          }

          GenServer.reply(from, reservation)
          dispatch(state)
        else
          schedule_wait(state, used, tokens, now)
        end
    end
  end

  defp eligible?(state, used, tokens, now) do
    now >= state.cooldown_until and now >= state.next_request_at and
      map_size(state.in_flight) < state.max_concurrency and
      used + tokens <= state.tokens_per_minute
  end

  defp used_tokens(state) do
    completed = Enum.sum(for {_ref, usage} <- state.usage, do: usage.tokens)
    active = Enum.sum(for {_ref, reservation} <- state.in_flight, do: reservation.tokens)
    completed + active
  end

  defp schedule_wait(state, used, tokens, now) do
    waits =
      [state.cooldown_until - now, state.next_request_at - now]
      |> Enum.filter(&(&1 > 0))

    waits =
      if used + tokens > state.tokens_per_minute and map_size(state.usage) > 0 do
        expiry = state.usage |> Enum.map(fn {_ref, usage} -> usage.expires_at end) |> Enum.min()
        [max(expiry - now, 1) | waits]
      else
        waits
      end

    case waits do
      [] -> state
      _some -> schedule(state, Enum.min(waits))
    end
  end

  defp schedule(state, delay) do
    tag = make_ref()
    timer_ref = Process.send_after(self(), {:dispatch, tag}, delay)
    %{state | timer: {tag, timer_ref}}
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: {_tag, timer_ref}} = state) do
    Process.cancel_timer(timer_ref)
    %{state | timer: nil}
  end

  defp expire_usage(state) do
    now = now_ms()
    %{state | usage: Map.reject(state.usage, fn {_ref, usage} -> usage.expires_at <= now end)}
  end

  defp request_interval(requests_per_second) when requests_per_second > 0 do
    ceil(1_000 / requests_per_second)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
