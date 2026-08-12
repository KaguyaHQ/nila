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
        # Chat fans out across pages and invoice segments, so 429/5xx backoff is
        # expected and replay has no business side effect. The custom policy is
        # intentionally narrower than Req's `:transient`: a POST is also retried
        # when the pure-H2 pool says it never accepted the request, but not for
        # ambiguous timeouts or connection closures that may have spent tokens.
        retry: &retry_policy/2,
        max_retries: Keyword.get(opts, :max_retries, 5),
        receive_timeout: receive_timeout()
      ]
      |> Keyword.merge(MistralChatFinch.req_options())
      |> Keyword.merge(req_options())

    case Req.post(options) do
      {:ok, %Req.Response{} = response} ->
        {:ok,
         %{status: response.status, headers: response.headers, body: to_binary(response.body)}}

      {:error, reason} ->
        {:error, {:mistral_chat_request_failed, reason}}
    end
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

  # Exponential with a floor: a rate-limited fan-out that all retries at once is
  # the same fan-out again.
  defp retry_delay(attempt), do: (:math.pow(2, attempt) * 1_000) |> round() |> min(30_000)

  @doc false
  def retry_policy(request, %Req.Response{status: status})
      when status in [429, 500, 502, 503, 504] do
    attempt = Req.Request.get_private(request, :req_retry_count, 0)
    {:delay, retry_delay(attempt)}
  end

  def retry_policy(_request, %Req.HTTPError{protocol: :http2, reason: reason})
      when reason in [:pool_not_available, :connection_not_ready, :unprocessed],
      # A real cold Mistral pool was still unavailable at 100ms and ready
      # within the next few hundred milliseconds. This error is proven
      # pre-send, so two short waits are safer than leaking process-start timing
      # into the extraction result.
      do: {:delay, 200}

  def retry_policy(_request, _response_or_error), do: false

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
