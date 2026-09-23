defmodule Nila.Assistant.HTTPClient.Stub do
  @moduledoc """
  Test HTTP client. Returns canned responses queued via `put_responses/1`.

  Backed by an ETS table named `:assistant_stub` so the queue is visible
  across callers, background tasks and the test process.
  The table is created lazily on first use.
  """
  @behaviour Nila.Assistant.HTTPClient

  @table :assistant_stub

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:public, :named_table, :ordered_set])
        :ok

      _ref ->
        :ok
    end
  end

  @doc """
  Replace the response queue. Each response is either:

    * `{:ok, %{status: integer(), body: map()}}`
    * `{:error, term()}`
  """
  def put_responses(responses) do
    ensure_table()
    :ets.delete_all_objects(@table)
    reset_calls()

    responses
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.each(fn {response, idx} ->
      :ets.insert(@table, {{:response, idx}, response})
    end)

    :ets.insert(@table, {:cursor, 0})
    :ok
  end

  @doc "Inspect the queued calls — used in assertions."
  def calls do
    ensure_table()

    @table
    |> :ets.match({{:call, :"$1"}, :"$2"})
    |> Enum.sort_by(fn [idx, _] -> idx end)
    |> Enum.map(fn [_, call] -> call end)
  end

  defp reset_calls do
    :ets.match_delete(@table, {{:call, :_}, :_})
    :ets.insert(@table, {:call_cursor, 0})
  end

  @impl true
  def post(url, body, headers) do
    ensure_table()
    record_call({url, body, headers})

    cursor =
      case :ets.lookup(@table, :cursor) do
        [{:cursor, n}] -> n
        [] -> 0
      end

    case :ets.lookup(@table, {:response, cursor}) do
      [{_, response}] ->
        :ets.insert(@table, {:cursor, cursor + 1})
        response

      [] ->
        {:error, :no_stub_response_staged}
    end
  end

  @impl true
  def post_stream(url, body, headers, acc, reducer) do
    ensure_table()
    record_call({url, body, headers})

    cursor =
      case :ets.lookup(@table, :cursor) do
        [{:cursor, n}] -> n
        [] -> 0
      end

    case :ets.lookup(@table, {:response, cursor}) do
      [{_, {:stream, chunks, response}}] ->
        :ets.insert(@table, {:cursor, cursor + 1})

        acc =
          chunks
          |> Enum.reduce(acc, reducer)
          |> then(&reducer.(:done, &1))

        with_acc(response, acc)

      [{_, {:ok, %{status: 200, body: %{"choices" => choices}}} = response}] ->
        :ets.insert(@table, {:cursor, cursor + 1})
        with_acc(response, stream_choices(choices, acc, reducer))

      [{_, response}] ->
        :ets.insert(@table, {:cursor, cursor + 1})
        with_acc(response, acc)

      [] ->
        {:error, :no_stub_response_staged}
    end
  end

  defp with_acc({:ok, response}, acc), do: {:ok, response, acc}
  defp with_acc({:error, _} = error, _acc), do: error

  defp stream_choices(choices, acc, reducer) do
    Enum.reduce(choices, acc, fn
      %{"message" => %{"content" => content}, "finish_reason" => reason}, acc
      when is_binary(content) ->
        acc =
          content
          |> String.graphemes()
          |> Enum.reduce(acc, fn token, acc ->
            reducer.(%{"choices" => [%{"delta" => %{"content" => token}}]}, acc)
          end)

        reducer.(%{"choices" => [%{"delta" => %{}, "finish_reason" => reason}]}, acc)

      %{"message" => %{"tool_calls" => tool_calls}, "finish_reason" => reason}, acc ->
        acc =
          tool_calls
          |> Enum.with_index()
          |> Enum.reduce(acc, fn {tool_call, index}, acc ->
            reducer.(
              %{
                "choices" => [
                  %{"delta" => %{"tool_calls" => [Map.put(tool_call, "index", index)]}}
                ]
              },
              acc
            )
          end)

        reducer.(%{"choices" => [%{"delta" => %{}, "finish_reason" => reason}]}, acc)

      _choice, acc ->
        acc
    end)
  end

  defp record_call(call) do
    call_idx =
      case :ets.lookup(@table, :call_cursor) do
        [{:call_cursor, n}] -> n
        [] -> 0
      end

    :ets.insert(@table, {{:call, call_idx}, call})
    :ets.insert(@table, {:call_cursor, call_idx + 1})
  end
end
