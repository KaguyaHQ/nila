defmodule Nila.Assistant do
  @moduledoc """
  Server-side tool-use loop against an OpenAI-compatible Chat Completions
  endpoint. Provider is selected entirely by config (`base_url`, `model`,
  `api_key`) — see `config/config.exs` and `config/runtime.exs`.

  Given the current scope and the running conversation, `chat/2` calls the
  configured endpoint, dispatches any `tool_calls` against
  `Nila.Assistant.Tools` (which scopes by `scope.current_org.id`), feeds tool
  results back in, and returns the assembled assistant turn.

  Conversation `turns` are plain maps:

      %{role: :user, text: "...", id: integer}
      %{role: :assistant, text: "...", attachments: [...], id: integer}

  Attachments are tagged tuples ready for the LiveView to render:
  `{:documents, [%{id: _, filename: _, ...}]}`.
  """

  alias Nila.Accounts.Scope
  alias Nila.Assistant.HTTPClient
  alias Nila.Assistant.StreamAccumulator
  alias Nila.Assistant.Tools
  alias Nila.Assistant.Trace

  def chat(%Scope{} = scope, turns, opts \\ []) when is_list(turns) do
    trace_topic = Keyword.get(opts, :trace_topic)

    messages =
      [%{"role" => "system", "content" => system_prompt()}] ++
        Enum.map(turns, &to_message/1)

    case tool_loop(scope, messages, 0, trace_topic, []) do
      {:ok, final_message, attachments} ->
        {:ok, %{turn: assemble_turn(final_message, attachments)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "System prompt — concise, with today's date so the model resolves 'last week' etc."
  def system_prompt do
    today = Date.utc_today() |> Date.to_iso8601()

    """
    You are the Nila operations assistant. You help the user find purchase orders \
    (POs) and invoice line items in the Nila system. Use the provided tools to look \
    up real data — never invent PO numbers, amounts, or customer names. When you \
    return a PO, the user will see a clickable card; you do not need to restate every \
    field in prose. Be concise. If a query is ambiguous, ask one clarifying question. \
    Today is #{today}.
    """
  end

  # ---- Tool loop ---------------------------------------------------------

  defp tool_loop(scope, messages, depth, trace_topic, attachments) do
    if depth >= max_iterations() do
      {:error, :tool_loop_exceeded}
    else
      started_at = System.monotonic_time(:millisecond)
      Trace.thinking(trace_topic, depth)

      case call_api(messages, trace_topic) do
        {:ok, %{"choices" => [%{"finish_reason" => "tool_calls", "message" => assistant_msg}]}} ->
          Trace.looking_up(trace_topic, depth, started_at)

          results =
            assistant_msg
            |> Map.get("tool_calls", [])
            |> Enum.map(&handle_tool_call(scope, &1, trace_topic))

          new_messages =
            messages ++ [strip_reasoning(assistant_msg)] ++ Enum.map(results, & &1.message)

          new_attachments = attachments ++ Enum.flat_map(results, & &1.attachments)

          tool_loop(scope, new_messages, depth + 1, trace_topic, new_attachments)

        {:ok, %{"choices" => [%{"message" => message} | _]}} ->
          Trace.answered(trace_topic, depth, started_at)
          {:ok, message, attachments}

        {:error, reason} ->
          Trace.request_failed(trace_topic, depth, reason, started_at)
          {:error, reason}
      end
    end
  end

  defp handle_tool_call(
         scope,
         %{"id" => id, "function" => %{"name" => name, "arguments" => args}},
         trace_topic
       ) do
    input = decode_arguments(args)
    started_at = System.monotonic_time(:millisecond)
    Trace.tool_started(trace_topic, id, name, input)

    {payload, attachments} =
      case Tools.dispatch(scope, name, input) do
        {:ok, %{results: results} = ok} ->
          Trace.tool_done(trace_topic, id, name, ok, started_at)
          {ok, attachments_for(name, results)}

        {:ok, single} when is_map(single) ->
          Trace.tool_done(trace_topic, id, name, single, started_at)
          {single, attachments_for(name, [single])}

        {:error, message} ->
          Trace.tool_failed(trace_topic, id, name, message, started_at)
          {%{error: message}, []}
      end

    %{message: tool_message(id, payload), attachments: attachments}
  end

  defp handle_tool_call(_scope, malformed, trace_topic) do
    id = Map.get(malformed, "id", "unknown")
    Trace.tool_malformed(trace_topic, id)
    %{message: tool_message(id, %{error: "malformed tool call"}), attachments: []}
  end

  defp decode_arguments(args) do
    case Jason.decode(args || "{}") do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp tool_message(id, payload) do
    %{"role" => "tool", "tool_call_id" => id, "content" => Jason.encode!(payload)}
  end

  defp strip_reasoning(msg) do
    msg
    |> Map.delete("reasoning_content")
    |> Map.delete("reasoning")
  end

  defp attachments_for(tool_name, results) do
    case attachment_tag(tool_name) do
      nil -> []
      tag -> [{tag, results}]
    end
  end

  defp attachment_tag("search_documents"), do: :documents
  defp attachment_tag(_), do: nil

  defp assemble_turn(final_message, raw_attachments) do
    text = Map.get(final_message, "content") || ""

    attachments =
      raw_attachments
      |> Enum.group_by(fn {tag, _} -> tag end, fn {_, results} -> results end)
      |> Enum.map(fn {tag, lists} -> {tag, List.flatten(lists)} end)

    %{
      role: :assistant,
      text: text,
      attachments: attachments,
      id: System.unique_integer([:positive])
    }
  end

  defp to_message(%{role: :user, text: text}), do: %{"role" => "user", "content" => text}

  defp to_message(%{role: :assistant, text: text}),
    do: %{"role" => "assistant", "content" => text}

  # ---- HTTP --------------------------------------------------------------

  defp call_api(messages, trace_topic) do
    config = Application.fetch_env!(:nila, __MODULE__)
    api_key = Keyword.fetch!(config, :api_key)
    base_url = Keyword.fetch!(config, :base_url)
    model = Keyword.fetch!(config, :model)
    max_tokens = Keyword.fetch!(config, :max_tokens)

    body =
      %{
        "model" => model,
        "max_tokens" => max_tokens,
        "messages" => messages,
        "tools" => tools_payload(),
        "tool_choice" => "auto"
      }
      |> maybe_put("temperature", Keyword.get(config, :temperature))
      |> maybe_put("top_p", Keyword.get(config, :top_p))
      |> maybe_merge_extra(Keyword.get(config, :extra_body))

    headers =
      %{
        "authorization" => "Bearer " <> api_key,
        "content-type" => "application/json",
        "accept" => "application/json"
      }
      |> maybe_merge_extra(Keyword.get(config, :extra_headers))

    url = String.trim_trailing(base_url, "/") <> "/chat/completions"

    request =
      if trace_topic do
        call_stream_api(url, body, headers, trace_topic)
      else
        HTTPClient.impl().post(url, body, headers)
      end

    case request do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: status}} when status in [400, 401, 403] ->
        {:error, :bad_request}

      {:ok, %{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %{status: status}} when status in [500, 502, 503, 504, 529] ->
        {:error, :upstream_overloaded}

      {:ok, %{status: _}} ->
        {:error, :unexpected_response}

      {:error, _reason} ->
        {:error, :network}
    end
  end

  defp call_stream_api(url, body, headers, trace_topic) do
    reducer = fn event, acc ->
      {acc, deltas} = StreamAccumulator.reduce(acc, event)
      Enum.each(deltas, &broadcast_delta(trace_topic, &1))
      acc
    end

    case HTTPClient.impl().post_stream(
           url,
           Map.put(body, "stream", true),
           headers,
           StreamAccumulator.new(),
           reducer
         ) do
      {:ok, %{status: 200}, acc} ->
        {:ok, %{status: 200, body: StreamAccumulator.to_body(acc)}}

      {:ok, %{status: status}, _acc} ->
        {:ok, %{status: status, body: nil}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp broadcast_delta(topic, text) do
    Phoenix.PubSub.broadcast(Nila.PubSub, topic, {:assistant_delta, text})
  end

  defp tools_payload do
    Enum.map(Tools.specs(), fn spec ->
      %{
        "type" => "function",
        "function" => %{
          "name" => spec.name,
          "description" => spec.description,
          "parameters" => spec.input_schema
        }
      }
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_merge_extra(map, nil), do: map
  defp maybe_merge_extra(map, extra) when is_map(extra), do: Map.merge(map, extra)

  defp max_iterations do
    Application.fetch_env!(:nila, __MODULE__)
    |> Keyword.fetch!(:max_tool_iterations)
  end
end
