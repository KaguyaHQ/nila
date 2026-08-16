defmodule Nila.Gst.Extraction.Providers.OpenAICompatibleChat do
  @moduledoc """
  OpenAI-compatible `/chat/completions` with a strict JSON schema: text in, JSON out.

  Mistral remains the OCR provider. The text provider is configured independently,
  so Mistral, Tencent TokenHub, Z.ai, or another compatible endpoint can be
  auditioned through the eval harness without changing the extraction pipeline.
  """

  @default_base_url "https://api.mistral.ai/v1"
  @default_model "mistral-small-latest"
  @default_provider "mistral"
  @json_object_prompt_version 1

  alias Nila.Gst.Extraction.OpenAICompatibleChatFinch

  require Logger

  @doc "The model this module will use unless a call overrides it."
  def model, do: config()[:model] || @default_model
  def provider, do: config()[:provider] || @default_provider
  def base_url, do: config()[:base_url] || @default_base_url
  def response_format, do: config()[:response_format] || :json_schema

  @doc """
  One completion constrained to `schema`, returning the raw response.

  Raw, because the eval harness caches response bytes at the network boundary
  and re-runs every pure step at score time; a helpfully pre-decoded body would
  put decoding on the wrong side of the cache.
  """
  def request_raw(messages, schema_name, schema, opts \\ []) when is_list(messages) do
    format = Keyword.get(opts, :response_format) || response_format()

    payload =
      %{
        model: Keyword.get(opts, :model) || model(),
        temperature: Keyword.get(opts, :temperature, 0),
        messages: messages(format, schema_name, schema, messages),
        response_format: response_format_payload(format, schema_name, schema)
      }
      |> maybe_put_provider_options()

    options =
      [
        url: url("/chat/completions"),
        auth: {:bearer, api_key()},
        json: payload,
        decode_body: false,
        retry: false,
        receive_timeout: receive_timeout()
      ]
      |> Keyword.merge(OpenAICompatibleChatFinch.req_options())
      |> Keyword.merge(req_options())

    request(
      options,
      payload.model,
      Keyword.get(opts, :max_retries, 8),
      0,
      schema,
      format
    )
  end

  @doc "Decodes and locally validates a cached or live response."
  def decode(response, schema \\ nil)

  def decode(%{status: status, body: body} = response, schema) when status in 200..299 do
    with {:ok, decoded} <- Jason.decode(body),
         %{"choices" => [%{"message" => %{"content" => content}} | _rest]} <- decoded,
         {:ok, parsed} <- decode_content(content),
         :ok <- validate(parsed, schema, Map.get(response, :response_format, response_format())) do
      {:ok, parsed, decoded["usage"] || %{}}
    else
      {:error, %Jason.DecodeError{} = reason} ->
        {:error, {:invalid_text_chat_response, reason}}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_text_chat_response, other}}
    end
  end

  def decode(%{status: status, body: body}, _schema) do
    {:error, {:text_chat_failed, status, decode_error_body(body)}}
  end

  defp decode_content(content) when is_binary(content), do: Jason.decode(content)
  defp decode_content(content) when is_map(content), do: {:ok, content}
  defp decode_content(_content), do: {:error, :invalid_text_chat_content}

  @doc "Cache key parts: the model plus a hash of the prompt and schema it is sent with."
  def fingerprint(prompt, schema) do
    %{
      provider: provider(),
      base_url: base_url(),
      model: model(),
      response_format: response_format(),
      prompt_version: @json_object_prompt_version,
      provider_options: config()[:provider_options] |> Jason.encode!() |> sha256(),
      prompt: sha256(prompt),
      schema: schema |> Jason.encode!() |> sha256()
    }
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp messages(format, _schema_name, _schema, messages)
       when format in [:json_schema, :json_schema_local],
       do: messages

  defp messages(:json_object, schema_name, schema, messages) do
    instruction =
      "Return one JSON object that validates against this JSON Schema. " <>
        "Return no prose or markdown. Schema name: #{schema_name}. Schema: #{Jason.encode!(schema)}"

    [%{role: "system", content: instruction} | messages]
  end

  defp response_format_payload(format, schema_name, schema)
       when format in [:json_schema, :json_schema_local] do
    %{type: "json_schema", json_schema: %{name: schema_name, strict: true, schema: schema}}
  end

  defp response_format_payload(:json_object, _schema_name, _schema), do: %{type: "json_object"}

  defp maybe_put_provider_options(payload) do
    case config()[:provider_options] do
      nil -> payload
      provider_options -> Map.put(payload, :providerOptions, provider_options)
    end
  end

  defp validate(_content, _schema, :json_schema), do: :ok

  defp validate(_content, nil, format) when format in [:json_object, :json_schema_local],
    do: {:error, :text_chat_schema_required}

  defp validate(content, schema, format) when format in [:json_object, :json_schema_local] do
    case JSV.validate(content, JSV.build!(schema)) do
      {:ok, _validated} -> :ok
      {:error, error} -> {:error, {:text_chat_schema_mismatch, JSV.normalize_error(error)}}
    end
  end

  defp request(options, request_model, max_retries, attempt, schema, format) do
    case Req.post(options) do
      {:ok, %Req.Response{} = response} ->
        raw = %{
          status: response.status,
          headers: response.headers,
          body: to_binary(response.body),
          response_format: format
        }

        cond do
          retryable_status?(response.status) and attempt < max_retries ->
            delay = retry_delay(response, attempt)
            log_retry(request_model, {:http_status, response.status}, attempt, max_retries, delay)
            wait(delay)
            request(options, request_model, max_retries, attempt + 1, schema, format)

          retryable_status?(response.status) ->
            log_retry_exhausted(request_model, {:http_status, response.status}, attempt)
            {:ok, raw}

          format in [:json_object, :json_schema_local] and response.status in 200..299 and
            not valid_response?(raw, schema) and attempt < max_retries ->
            request(options, request_model, max_retries, attempt + 1, schema, format)

          true ->
            {:ok, raw}
        end

      {:error, %Req.HTTPError{protocol: :http2, reason: reason} = error}
      when reason in [:pool_not_available, :connection_not_ready, :unprocessed] ->
        if attempt < max_retries do
          delay = jitter(200)
          log_retry(request_model, {:http2, reason}, attempt, max_retries, delay)
          wait(delay)
          request(options, request_model, max_retries, attempt + 1, schema, format)
        else
          log_retry_exhausted(request_model, {:http2, reason}, attempt)
          {:error, {:text_chat_request_failed, error}}
        end

      {:error, reason} ->
        {:error, {:text_chat_request_failed, reason}}
    end
  end

  defp log_retry(request_model, reason, attempt, max_retries, delay) do
    Logger.warning(
      "gst_text.retry provider=#{provider()} model=#{request_model} " <>
        "reason=#{inspect(reason)} retry=#{attempt + 1}/#{max_retries} delay_ms=#{delay}",
      retry_metadata(request_model, reason) ++
        [attempt: attempt + 1, max_retries: max_retries, delay_ms: delay]
    )
  end

  defp log_retry_exhausted(request_model, reason, attempt) do
    Logger.warning(
      "gst_text.retry_exhausted provider=#{provider()} model=#{request_model} " <>
        "reason=#{inspect(reason)} attempts=#{attempt + 1}",
      retry_metadata(request_model, reason) ++ [attempts: attempt + 1]
    )
  end

  defp retry_metadata(request_model, {:http_status, status}),
    do: [
      provider: provider(),
      model: request_model,
      retry_kind: :http_status,
      http_status: status
    ]

  defp retry_metadata(request_model, {:http2, reason}),
    do: [provider: provider(), model: request_model, retry_kind: :http2, transport_reason: reason]

  defp wait(delay), do: (config()[:retry_wait] || (&default_wait/1)).(delay)

  defp default_wait(delay) do
    receive do
    after
      delay -> :ok
    end
  end

  defp valid_response?(response, schema), do: match?({:ok, _, _}, decode(response, schema))

  defp retryable_status?(status), do: status in [429, 500, 502, 503, 504]

  defp retry_delay(%Req.Response{status: 429, headers: headers}, attempt) do
    max(header_delay(headers), exponential_delay(attempt)) + jitter(500)
  end

  defp retry_delay(_response, attempt), do: exponential_delay(attempt) + jitter(500)

  defp exponential_delay(attempt),
    do: (:math.pow(2, attempt) * 1_000) |> round() |> min(30_000)

  defp jitter(maximum), do: :rand.uniform(maximum + 1) - 1

  defp header_delay(headers) do
    retry_after = headers |> Map.get("retry-after", []) |> Enum.map(&parse_retry_after/1)

    resets =
      ["x-ratelimit-reset", "x-ratelimit-reset-requests", "x-ratelimit-reset-tokens"]
      |> Enum.flat_map(&Map.get(headers, &1, []))
      |> Enum.map(&parse_reset/1)

    Enum.max(retry_after ++ resets, fn -> 0 end)
  end

  defp parse_retry_after(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} -> seconds * 1_000
      _not_seconds -> http_date_delay(value)
    end
  end

  defp parse_retry_after(_value), do: 0

  defp parse_reset(value) when is_binary(value) do
    cond do
      Regex.match?(~r/^\d+ms$/, value) ->
        value |> String.trim_trailing("ms") |> String.to_integer()

      Regex.match?(~r/^\d+(\.\d+)?s$/, value) ->
        seconds = String.trim_trailing(value, "s")

        value =
          if String.contains?(seconds, "."),
            do: String.to_float(seconds),
            else: String.to_integer(seconds)

        round(value * 1_000)

      Regex.match?(~r/^\d+$/, value) ->
        reset_from_integer(String.to_integer(value))

      true ->
        0
    end
  end

  defp parse_reset(_value), do: 0

  defp reset_from_integer(value) when value > 10_000_000_000,
    do: max(value - System.os_time(:millisecond), 0)

  defp reset_from_integer(value) when value > 1_000_000_000,
    do: max(value - System.os_time(:second), 0) * 1_000

  defp reset_from_integer(value), do: value * 1_000

  defp http_date_delay(value) do
    case :httpd_util.convert_request_date(String.to_charlist(value)) do
      :bad_date ->
        0

      datetime ->
        unix_epoch = {{1970, 1, 1}, {0, 0, 0}} |> :calendar.datetime_to_gregorian_seconds()
        reset = :calendar.datetime_to_gregorian_seconds(datetime) - unix_epoch
        max(reset - System.os_time(:second), 0) * 1_000
    end
  end

  defp to_binary(body) when is_binary(body), do: body
  defp to_binary(body), do: IO.iodata_to_binary(body)

  defp decode_error_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> body
    end
  end

  defp decode_error_body(body), do: body

  defp config, do: Application.get_env(:nila, __MODULE__, [])
  defp api_key, do: config()[:api_key]
  defp url(path), do: String.trim_trailing(base_url(), "/") <> path
  defp receive_timeout, do: config()[:receive_timeout] || 300_000
  defp req_options, do: config()[:req_options] || []
end
