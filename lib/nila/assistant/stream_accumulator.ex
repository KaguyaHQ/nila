defmodule Nila.Assistant.StreamAccumulator do
  @moduledoc """
  Folds OpenAI-style streaming chat-completion SSE events into a single
  assembled response body.

  Pure — no PubSub, no process state. `reduce/2` returns the updated
  accumulator together with any content fragments the event carried, so the
  caller (`Nila.Assistant`) decides how to forward those deltas (e.g. to the
  LiveView). `to_body/1` rebuilds the non-streaming `%{"choices" => [...]}`
  shape the tool loop already understands, so streaming is invisible upstream.
  """

  def new, do: %{role: "assistant", content: "", finish_reason: nil, tool_calls: %{}}

  @doc """
  Fold one SSE event into the accumulator. Returns `{acc, deltas}` where
  `deltas` is the content fragments the event carried (usually one, sometimes
  none), in arrival order.
  """
  def reduce(acc, :done), do: {acc, []}

  def reduce(acc, %{"choices" => choices}) when is_list(choices) do
    Enum.reduce(choices, {acc, []}, fn choice, {acc, deltas} ->
      delta = Map.get(choice, "delta", %{})
      acc = merge_delta(acc, delta)

      deltas =
        case Map.get(delta, "content") do
          text when is_binary(text) and text != "" -> deltas ++ [text]
          _ -> deltas
        end

      acc =
        case Map.get(choice, "finish_reason") do
          reason when is_binary(reason) -> %{acc | finish_reason: reason}
          _ -> acc
        end

      {acc, deltas}
    end)
  end

  def reduce(acc, _event), do: {acc, []}

  @doc "Assemble the accumulator into the buffered OpenAI response shape."
  def to_body(acc) do
    message =
      %{"role" => acc.role, "content" => acc.content}
      |> maybe_put_tool_calls(acc.tool_calls)

    %{
      "choices" => [
        %{
          "finish_reason" => acc.finish_reason || "stop",
          "message" => message
        }
      ]
    }
  end

  # ---- delta merging ----------------------------------------------------

  defp merge_delta(acc, delta) do
    acc
    |> merge_role(delta)
    |> merge_content(delta)
    |> merge_tool_calls(delta)
  end

  defp merge_role(acc, %{"role" => role}) when is_binary(role), do: %{acc | role: role}
  defp merge_role(acc, _delta), do: acc

  defp merge_content(acc, %{"content" => content}) when is_binary(content),
    do: %{acc | content: acc.content <> content}

  defp merge_content(acc, _delta), do: acc

  defp merge_tool_calls(acc, %{"tool_calls" => tool_calls}) when is_list(tool_calls) do
    tool_calls =
      Enum.reduce(tool_calls, acc.tool_calls, fn tool_call, tool_calls ->
        index = Map.get(tool_call, "index", map_size(tool_calls))
        existing = Map.get(tool_calls, index, %{"function" => %{"arguments" => ""}})
        Map.put(tool_calls, index, merge_tool_call(existing, tool_call))
      end)

    %{acc | tool_calls: tool_calls}
  end

  defp merge_tool_calls(acc, _delta), do: acc

  defp merge_tool_call(existing, delta) do
    delta_function = Map.get(delta, "function", %{})

    function =
      existing
      |> Map.get("function", %{"arguments" => ""})
      |> put_value("name", Map.get(delta_function, "name"))
      |> update_in(["arguments"], fn args ->
        (args || "") <> (Map.get(delta_function, "arguments") || "")
      end)

    existing
    |> put_value("id", Map.get(delta, "id"))
    |> put_value("type", Map.get(delta, "type"))
    |> Map.put("function", function)
  end

  defp put_value(map, _key, nil), do: map
  defp put_value(map, _key, ""), do: map
  defp put_value(map, key, value), do: Map.put(map, key, value)

  # ---- assembly ---------------------------------------------------------

  defp maybe_put_tool_calls(message, tool_calls) when map_size(tool_calls) == 0, do: message

  defp maybe_put_tool_calls(message, tool_calls) do
    calls =
      tool_calls
      |> Enum.sort_by(fn {index, _call} -> index end)
      |> Enum.map(fn {_index, call} -> call end)

    message
    |> Map.put("content", nil)
    |> Map.put("tool_calls", calls)
  end
end
