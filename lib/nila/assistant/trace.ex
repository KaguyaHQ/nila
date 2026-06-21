defmodule Nila.Assistant.Trace do
  @moduledoc """
  Builds and broadcasts the user-facing "what the assistant is doing" trace
  steps rendered in `NilaWeb.AssistantLive`.

  This module owns the trace vocabulary — step ids, statuses, and copy — so the
  loop in `Nila.Assistant` narrates the run in prose (`Trace.thinking/2`,
  `Trace.tool_done/5`) instead of hand-assembling event maps. Steps are
  delivered as `{:assistant_trace, event}` PubSub messages where `event` is
  `%{id, status, title, detail, elapsed_ms}`.

  Every function takes a `topic`; a `nil` topic is a no-op, so the loop runs
  untraced (the buffered, non-streaming path) without branching at each site.
  """

  # ---- model round ------------------------------------------------------

  @doc "Mark the start of a model round; pairs with `answered/3` or `looking_up/3`."
  def thinking(topic, depth) do
    emit(topic, %{
      id: model_id(depth),
      status: :running,
      title: "Thinking…",
      detail: "Working through your question."
    })
  end

  @doc "The model asked for tools — it's about to look records up."
  def looking_up(topic, depth, started_at) do
    emit(topic, %{
      id: model_id(depth),
      status: :done,
      title: "Looking up records…",
      detail: "Checking system records before answering.",
      elapsed_ms: elapsed_ms(started_at)
    })
  end

  @doc "The model produced its final answer — no more lookups."
  def answered(topic, depth, started_at) do
    emit(topic, %{
      id: model_id(depth),
      status: :done,
      title: "Answer ready",
      detail: "Finished — no more lookups needed.",
      elapsed_ms: elapsed_ms(started_at)
    })
  end

  @doc "The model request itself failed (network, rate limit, upstream)."
  def request_failed(topic, depth, reason, started_at) do
    emit(topic, %{
      id: model_id(depth),
      status: :error,
      title: "Request failed",
      detail: inspect(reason),
      elapsed_ms: elapsed_ms(started_at)
    })
  end

  # ---- tool step --------------------------------------------------------

  def tool_started(topic, call_id, name, input) do
    emit(topic, %{
      id: tool_id(call_id),
      status: :running,
      title: started_title(name, input),
      detail: input_detail(input)
    })
  end

  def tool_done(topic, call_id, name, payload, started_at) do
    emit(topic, %{
      id: tool_id(call_id),
      status: :done,
      title: done_title(name, payload),
      detail: done_detail(name, payload),
      elapsed_ms: elapsed_ms(started_at)
    })
  end

  def tool_failed(topic, call_id, name, message, started_at) do
    emit(topic, %{
      id: tool_id(call_id),
      status: :error,
      title: error_title(name),
      detail: message,
      elapsed_ms: elapsed_ms(started_at)
    })
  end

  def tool_malformed(topic, call_id) do
    emit(topic, %{
      id: tool_id(call_id),
      status: :error,
      title: "Skipped malformed tool call",
      detail: "The model returned a tool call Nila could not parse."
    })
  end

  # ---- copy -------------------------------------------------------------

  defp started_title("search_pos", input) do
    cond do
      present?(input["status"]) -> "Searching #{input["status"]} purchase orders..."
      present?(input["customer_name"]) -> "Searching POs for #{input["customer_name"]}..."
      present?(input["query"]) -> "Searching POs for #{input["query"]}..."
      true -> "Searching purchase orders..."
    end
  end

  defp started_title("get_po", input) do
    case input["id"] || input[:id] do
      nil -> "Loading purchase order..."
      id -> "Loading PO #{id}..."
    end
  end

  defp started_title("search_line_items", input) do
    cond do
      present?(input["po_number"]) -> "Searching line items for #{input["po_number"]}..."
      present?(input["customer_name"]) -> "Searching line items for #{input["customer_name"]}..."
      present?(input["query"]) -> "Searching line items for #{input["query"]}..."
      true -> "Searching line items..."
    end
  end

  defp started_title(name, _input), do: "Running #{name}..."

  defp done_title("search_pos", payload),
    do: "Found #{pluralize(result_count(payload), "purchase order")}"

  defp done_title("search_line_items", payload),
    do: "Found #{pluralize(result_count(payload), "line item")}"

  defp done_title("get_po", payload) do
    case payload[:po_number] || payload["po_number"] do
      nil -> "Loaded purchase order"
      po_number -> "Loaded #{po_number}"
    end
  end

  defp done_title(name, _payload), do: "Finished #{name}"

  defp error_title("search_pos"), do: "Purchase order search failed"
  defp error_title("get_po"), do: "Purchase order load failed"
  defp error_title("search_line_items"), do: "Line item search failed"
  defp error_title(name), do: "#{name} failed"

  defp input_detail(input) when map_size(input) == 0, do: "No filters."

  defp input_detail(input) do
    input
    |> Enum.map(fn {key, value} -> "#{key}: #{value}" end)
    |> Enum.join(", ")
  end

  defp done_detail("get_po", payload) do
    status = payload[:status] || payload["status"]
    customer = payload[:customer_name] || payload["customer_name"]

    [customer, status]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "Loaded record details."
      parts -> Enum.join(parts, " · ")
    end
  end

  defp done_detail(_name, payload) do
    "Returned #{pluralize(result_count(payload), "record")}."
  end

  defp result_count(%{count: count}) when is_integer(count), do: count
  defp result_count(%{"count" => count}) when is_integer(count), do: count
  defp result_count(%{results: results}) when is_list(results), do: length(results)
  defp result_count(%{"results" => results}) when is_list(results), do: length(results)
  defp result_count(_payload), do: 1

  defp pluralize(1, noun), do: "1 #{noun}"
  defp pluralize(count, noun), do: "#{count} #{noun}s"

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  # ---- emit -------------------------------------------------------------

  defp emit(nil, _event), do: :ok

  defp emit(topic, event) do
    Phoenix.PubSub.broadcast(Nila.PubSub, topic, {:assistant_trace, event})
  end

  defp model_id(depth), do: "model-#{depth}"
  defp tool_id(call_id), do: "tool-#{call_id}"

  defp elapsed_ms(started_at), do: System.monotonic_time(:millisecond) - started_at
end
