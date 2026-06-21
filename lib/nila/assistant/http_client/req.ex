defmodule Nila.Assistant.HTTPClient.Req do
  @moduledoc """
  Real OpenAI-compatible chat completions API client backed by Req.

  Supports both buffered (`post/3`) and streaming SSE (`post_stream/5`) requests.
  """
  @behaviour Nila.Assistant.HTTPClient

  @impl true
  def post(url, body, headers) when is_binary(url) and is_map(body) and is_map(headers) do
    case Req.post(url,
           json: body,
           headers: Map.to_list(headers),
           receive_timeout: receive_timeout()
         ) do
      {:ok, %Req.Response{status: status, body: body}} ->
        {:ok, %{status: status, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def post_stream(url, body, headers, acc, reducer)
      when is_binary(url) and is_map(body) and is_map(headers) and is_function(reducer, 2) do
    headers =
      headers
      |> Map.put("accept", "text/event-stream")
      |> Map.to_list()

    result =
      Req.post(url,
        json: body,
        headers: headers,
        receive_timeout: receive_timeout(),
        # Thread the partial SSE buffer and the caller's accumulator through the
        # response's :private map. Req only ever hands us `{req, resp}`, so this
        # keeps streaming state out of the process dictionary.
        into: fn {:data, data}, {req, resp} ->
          {buffer, acc} = Req.Response.get_private(resp, :sse_state, {"", acc})
          {buffer, acc} = process_sse_chunk(buffer, data, acc, reducer)
          {:cont, {req, Req.Response.put_private(resp, :sse_state, {buffer, acc})}}
        end
      )

    case result do
      {:ok, %Req.Response{status: status} = resp} ->
        {_buffer, acc} = Req.Response.get_private(resp, :sse_state, {"", acc})
        {:ok, %{status: status}, acc}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp receive_timeout do
    :nila
    |> Application.get_env(Nila.Assistant, [])
    |> Keyword.get(:receive_timeout, 60_000)
  end

  defp process_sse_chunk(buffer, data, acc, reducer) do
    buffer = buffer <> String.replace(data, "\r\n", "\n")
    {events, rest} = split_sse_events(buffer)
    acc = Enum.reduce(events, acc, &decode_sse_event(&1, &2, reducer))
    {rest, acc}
  end

  defp split_sse_events(buffer) do
    parts = String.split(buffer, "\n\n")

    case String.ends_with?(buffer, "\n\n") do
      true -> {parts |> Enum.reject(&(&1 == "")), ""}
      false -> {Enum.drop(parts, -1), List.last(parts) || ""}
    end
  end

  # Assumes OpenAI-style SSE: one JSON object per `data:` line, terminated by a
  # `data: [DONE]` sentinel. Other SSE fields (event:, id:, retry:, comments)
  # are not used by this endpoint and are ignored.
  defp decode_sse_event(event, acc, reducer) do
    event
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data:"))
    |> Enum.map(fn line -> line |> String.replace_prefix("data:", "") |> String.trim() end)
    |> Enum.reduce(acc, fn
      "[DONE]", acc ->
        reducer.(:done, acc)

      data, acc ->
        case Jason.decode(data) do
          {:ok, decoded} -> reducer.(decoded, acc)
          {:error, _} -> acc
        end
    end)
  end
end
