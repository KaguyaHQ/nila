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
       reservations: %{},
       tokens_per_minute:
         Keyword.get(opts, :tokens_per_minute, config[:tokens_per_minute] || 100_000),
       request_interval_ms:
         request_interval(
           Keyword.get(opts, :requests_per_second, config[:requests_per_second] || 1.67)
         ),
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
    reservations =
      case state.reservations do
        %{^reservation => reservation_state} ->
          Map.put(state.reservations, reservation, %{
            reservation_state
            | tokens: min(actual_tokens, state.tokens_per_minute)
          })

        _missing ->
          state.reservations
      end

    {:reply, :ok, dispatch(%{state | reservations: reservations})}
  end

  def handle_call({:release, reservation, delay_ms}, _from, state) do
    state = %{
      state
      | reservations: Map.delete(state.reservations, reservation),
        cooldown_until: max(state.cooldown_until, now_ms() + delay_ms)
    }

    {:reply, :ok, dispatch(state)}
  end

  @impl true
  def handle_info({:dispatch, timer}, %{timer: timer} = state),
    do: {:noreply, dispatch(%{state | timer: nil})}

  def handle_info({:dispatch, _stale}, state), do: {:noreply, state}

  defp dispatch(state) do
    state = state |> cancel_timer() |> expire_reservations()

    case :queue.peek(state.queue) do
      :empty ->
        state

      {:value, {from, tokens}} ->
        now = now_ms()
        used = Enum.sum(for {_ref, reservation} <- state.reservations, do: reservation.tokens)

        if now >= state.cooldown_until and now >= state.next_request_at and
             used + tokens <= state.tokens_per_minute do
          {{:value, {^from, ^tokens}}, queue} = :queue.out(state.queue)
          reservation = make_ref()

          state = %{
            state
            | queue: queue,
              reservations:
                Map.put(state.reservations, reservation, %{
                  tokens: tokens,
                  expires_at: now + @window_ms
                }),
              next_request_at: now + state.request_interval_ms
          }

          GenServer.reply(from, reservation)
          dispatch(state)
        else
          schedule(state, wait_ms(state, used, tokens, now))
        end
    end
  end

  defp wait_ms(state, used, tokens, now) do
    waits = [state.cooldown_until - now, state.next_request_at - now]

    waits =
      if used + tokens > state.tokens_per_minute do
        expiry =
          state.reservations
          |> Enum.map(fn {_ref, reservation} -> reservation.expires_at end)
          |> Enum.min()

        [expiry - now | waits]
      else
        waits
      end

    waits |> Enum.max() |> max(1)
  end

  defp schedule(state, delay) do
    timer = make_ref()
    Process.send_after(self(), {:dispatch, timer}, delay)
    %{state | timer: timer}
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(state), do: %{state | timer: nil}

  defp expire_reservations(state) do
    now = now_ms()

    reservations =
      Map.reject(state.reservations, fn {_ref, reservation} -> reservation.expires_at <= now end)

    %{state | reservations: reservations}
  end

  defp request_interval(requests_per_second) when requests_per_second > 0 do
    ceil(1_000 / requests_per_second)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
