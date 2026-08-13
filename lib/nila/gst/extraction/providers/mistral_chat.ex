defmodule Nila.Gst.Extraction.Providers.MistralChat do
  @moduledoc """
  `/v1/chat/completions` with a strict JSON schema: text in, JSON out.

  The sibling `Providers.Mistral` calls `/v1/ocr`, which takes pixels and returns
  transcription *and* interpretation fused into one call. Fusing them is what
  forced windows: the interpretation half has a per-call output budget, so the
  page count had to shrink until the budget fit, which made a transport decision
  into a semantic one.

  Splitting them off here buys three things the fused call cannot give:

    * the input is text, so its size is measurable *before* the call — a segment
      with 200 table rows can be spotted and split rather than discovered
      truncated afterwards;
    * the call is replayable offline against cached transcription bytes, so a
      prompt change costs no OCR; and
    * the model is a config knob (`GST_DISCOVERY_MODEL`, `GST_EXTRACT_MODEL`),
      auditioned through the eval harness rather than by a rewrite.

  Credentials fall back to the OCR provider's config so one `MISTRAL_API_KEY`
  configures both.
  """

  @default_model "mistral-small-latest"

  alias Nila.Gst.Extraction.MistralChatFinch
  alias Nila.Gst.Extraction.ProviderAdmission

  @doc "The model this module will use unless a call overrides it."
  def model, do: config()[:model] || @default_model

  def provider, do: "mistral-chat"

  @doc """
  One completion constrained to `schema`, returning the raw response.

  Raw, because the eval harness caches response bytes at the network boundary
  and re-runs every pure step at score time; a helpfully pre-decoded body would
  put decoding on the wrong side of the cache.
  """
  def request_raw(messages, schema_name, schema, opts \\ []) when is_list(messages) do
    payload = %{
      model: Keyword.get(opts, :model) || model(),
      temperature: Keyword.get(opts, :temperature, 0),
      messages: messages,
      response_format: %{
        type: "json_schema",
        json_schema: %{name: schema_name, strict: true, schema: schema}
      }
    }

    options =
      [
        url: url("/v1/chat/completions"),
        auth: {:bearer, api_key()},
        json: payload,
        decode_body: false,
        retry: false,
        receive_timeout: receive_timeout()
      ]
      |> Keyword.merge(MistralChatFinch.req_options())
      |> Keyword.merge(req_options())

    request(options, estimate_tokens(payload), Keyword.get(opts, :max_retries, 8), 0)
  end

  @doc "Decodes a cached or live response into `{:ok, content_map, usage}`."
  def decode(%{status: status, body: body}) when status in 200..299 do
    with {:ok, decoded} <- Jason.decode(body),
         %{"choices" => [%{"message" => %{"content" => content}} | _rest]} <- decoded,
         {:ok, parsed} <- decode_content(content) do
      {:ok, parsed, decoded["usage"] || %{}}
    else
      {:error, %Jason.DecodeError{} = reason} ->
        {:error, {:invalid_mistral_chat_response, reason}}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_mistral_chat_response, other}}
    end
  end

  def decode(%{status: status, body: body}) do
    {:error, {:mistral_chat_failed, status, decode_error_body(body)}}
  end

  defp decode_content(content) when is_binary(content), do: Jason.decode(content)
  defp decode_content(content) when is_map(content), do: {:ok, content}
  defp decode_content(_content), do: {:error, :invalid_mistral_chat_content}

  @doc "Cache key parts: the model plus a hash of the prompt and schema it is sent with."
  def fingerprint(prompt, schema) do
    %{
      model: model(),
      prompt: sha256(prompt),
      schema: schema |> Jason.encode!() |> sha256()
    }
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp request(options, estimated_tokens, max_retries, attempt) do
    reservation = ProviderAdmission.acquire(estimated_tokens)

    case Req.post(options) do
      {:ok, %Req.Response{} = response} ->
        raw = %{
          status: response.status,
          headers: response.headers,
          body: to_binary(response.body)
        }

        if retryable_status?(response.status) do
          delay = retry_delay(response, attempt)
          ProviderAdmission.release(reservation, delay)

          if attempt < max_retries do
            request(options, estimated_tokens, max_retries, attempt + 1)
          else
            {:ok, raw}
          end
        else
          ProviderAdmission.reconcile(reservation, response_tokens(raw, estimated_tokens))
          {:ok, raw}
        end

      {:error, %Req.HTTPError{protocol: :http2, reason: reason} = error}
      when reason in [:pool_not_available, :connection_not_ready, :unprocessed] ->
        ProviderAdmission.release(reservation, jitter(200))

        if attempt < max_retries do
          request(options, estimated_tokens, max_retries, attempt + 1)
        else
          {:error, {:mistral_chat_request_failed, error}}
        end

      {:error, reason} ->
        ProviderAdmission.reconcile(reservation, estimated_tokens)
        {:error, {:mistral_chat_request_failed, reason}}
    end
  end

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

  defp estimate_tokens(payload) do
    payload
    |> Jason.encode!()
    |> byte_size()
    |> div(4)
    |> Kernel.+(1_024)
  end

  defp response_tokens(response, fallback) do
    case Jason.decode(response.body) do
      {:ok, %{"usage" => %{"total_tokens" => tokens}}} when is_integer(tokens) -> tokens
      _missing -> fallback
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
  defp ocr_config, do: Application.get_env(:nila, Nila.Gst.Extraction.Providers.Mistral, [])
  defp api_key, do: config()[:api_key] || ocr_config()[:api_key]
  defp base_url, do: config()[:base_url] || ocr_config()[:base_url] || "https://api.mistral.ai"
  defp url(path), do: base_url() <> path
  defp receive_timeout, do: config()[:receive_timeout] || 300_000
  defp req_options, do: config()[:req_options] || ocr_config()[:req_options] || []
end
