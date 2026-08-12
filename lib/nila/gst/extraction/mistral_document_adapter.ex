defmodule Nila.Gst.Extraction.MistralDocumentAdapter do
  @moduledoc """
  Req adapter for one-off Mistral OCR and Files API requests.

  Document calls are sparse, large, and expensive. Reusing a long-idle Finch
  HTTP/1 connection produced a black-holed OCR request in production-like local
  testing; expiring Finch connections later produced a pool checkout failure.
  Hackney's `pool: false` is the stronger boundary for this workload: every
  adapter invocation owns a new HTTP/1 connection and no completed or failed
  document socket can be selected by a later request.

  Req still owns request encoding, authentication, redirects, response decoding,
  and the explicit `retry: false` policy at the provider call sites. This adapter
  is deliberately buffered and supports only the GET, POST, and DELETE methods
  used by Mistral's OCR and Files APIs.

  See `docs/mistral-http-transport.md` for the evidence and tradeoffs.
  """

  @event_prefix [:nila, :mistral, :document, :request]
  @supported_methods [:get, :post, :delete]

  @doc false
  def run(%Req.Request{} = request) do
    with :ok <- validate(request),
         {:ok, body} <- body(request.body) do
      metadata = metadata(request)

      :telemetry.span(@event_prefix, metadata, fn ->
        result = request(request, body)
        {result, Map.merge(metadata, stop_metadata(result))}
      end)
    else
      {:error, exception} -> {request, exception}
    end
  end

  @doc false
  def hackney_options(%Req.Request{} = request) do
    connect_options = request.options[:connect_options] || []
    receive_timeout = request.options[:receive_timeout] || 15_000

    [
      pool: false,
      protocols: [:http1],
      connect_timeout: Keyword.get(connect_options, :timeout, 30_000),
      send_timeout: receive_timeout,
      recv_timeout: receive_timeout
    ]
  end

  defp request(request, body) do
    result =
      :hackney.request(
        request.method,
        URI.to_string(request.url),
        Req.Fields.get_list(request.headers),
        body,
        hackney_options(request)
      )

    case result do
      {:ok, status, headers, response_body} ->
        {request,
         Req.Response.new(
           status: status,
           headers: normalize_headers(headers),
           body: response_body
         )}

      {:ok, status, headers} ->
        {request, Req.Response.new(status: status, headers: normalize_headers(headers))}

      {:error, reason} ->
        {request, %Req.TransportError{reason: normalize_reason(reason)}}
    end
  end

  defp validate(%Req.Request{method: method}) when method not in @supported_methods do
    {:error,
     ArgumentError.exception(
       "Mistral document adapter supports only GET, POST, and DELETE; got #{inspect(method)}"
     )}
  end

  defp validate(%Req.Request{into: nil}), do: :ok

  defp validate(%Req.Request{}) do
    {:error,
     ArgumentError.exception("Mistral document adapter does not support streaming responses")}
  end

  defp body(nil), do: {:ok, <<>>}
  defp body(body) when is_binary(body) or is_list(body), do: {:ok, body}

  defp body(_body) do
    {:error, ArgumentError.exception("Mistral document adapter requires a buffered request body")}
  end

  defp normalize_headers(headers) do
    Enum.map(headers, fn {name, value} ->
      {name |> to_string() |> String.downcase(:ascii), to_string(value)}
    end)
  end

  defp normalize_reason(reason) when reason in [:connect_timeout, :recv_timeout], do: :timeout
  defp normalize_reason(reason), do: reason

  defp metadata(request) do
    %{
      provider: :mistral,
      method: request.method,
      origin: origin(request.url),
      path: path_template(request.url.path || "/"),
      protocol: :http1,
      connection_policy: :unpooled
    }
  end

  defp path_template("/v1/ocr"), do: "/v1/ocr"
  defp path_template("/v1/files"), do: "/v1/files"

  defp path_template(path) do
    case String.split(path, "/", trim: true) do
      ["v1", "files", _file_id, "url"] -> "/v1/files/:id/url"
      ["v1", "files", _file_id] -> "/v1/files/:id"
      _other -> "/other"
    end
  end

  defp origin(uri) do
    uri
    |> Map.put(:path, nil)
    |> Map.put(:query, nil)
    |> Map.put(:fragment, nil)
    |> Map.put(:userinfo, nil)
    |> URI.to_string()
  end

  defp stop_metadata({_request, %Req.Response{status: status}}),
    do: %{outcome: :ok, status: status}

  defp stop_metadata({_request, exception}),
    do: %{outcome: :error, error: exception.__struct__, reason: Map.get(exception, :reason)}
end
